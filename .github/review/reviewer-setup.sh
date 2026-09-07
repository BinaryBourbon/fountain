#!/bin/sh
# Review Loop executes these bytes from the approved base after exact-head checkout.
set -eu
: "${REVIEW_LOOP_BASE:?missing trusted base}"
: "${REVIEW_LOOP_HEAD:?missing expected head}"
: "${REVIEW_LOOP_WORKSPACE:?missing checkout path}"
cd "$REVIEW_LOOP_WORKSPACE"
test "$(git rev-parse HEAD)" = "$REVIEW_LOOP_HEAD"

# Reuse the protected verifier bootstrap at the approved revision. Never source
# the PR's copy. The temporary file also preserves a failed git-show exit code.
rl_reviewer_bootstrap=$(mktemp)
trap 'rm -f "$rl_reviewer_bootstrap"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
git show "$REVIEW_LOOP_BASE:.github/review/setup.sh" > "$rl_reviewer_bootstrap"
sh "$rl_reviewer_bootstrap"
# Hex 2.5.1/httpc ignores an HTTPS proxy's scheme. Keep the remote hop
# encrypted and authenticated: a loopback-only TLS relay carries its CONNECT.
# The proxy credential stays in child process environments, never a file/argv.
if [ -n "${HTTPS_PROXY:-}" ]; then
  if [ "$(id -u)" = 0 ]; then
    env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends socat
  else
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends socat
  fi
  python3 - <<'PY_RELAY'
import os
import pathlib
import re
import socket
import subprocess
import time
from urllib.parse import urlsplit

proxy = urlsplit(os.environ["HTTPS_PROXY"])
if proxy.scheme != "https" or not proxy.hostname or not re.fullmatch(r"[A-Za-z0-9.-]+", proxy.hostname):
    raise SystemExit("Reviewer setup requires an HTTPS broker with a DNS hostname")
port = 18443
# Fail rather than reuse a listener left by unrelated work.
with socket.socket() as check:
    check.bind(("127.0.0.1", port))
relay = subprocess.Popen([
    "socat", f"TCP4-LISTEN:{port},bind=127.0.0.1,reuseaddr,fork",
    f"OPENSSL:{proxy.hostname}:{proxy.port or 443},verify=1,"
    f"cafile=/etc/ssl/certs/ca-certificates.crt,commonname={proxy.hostname},snihost={proxy.hostname}",
], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
   start_new_session=True)
for _ in range(50):
    if relay.poll() is not None:
        raise SystemExit("Reviewer broker TLS relay failed to start")
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
            break
    except OSError:
        time.sleep(0.1)
else:
    relay.terminate()
    raise SystemExit("Reviewer broker TLS relay did not become ready")

# The verified bootstrap owns this directory. Wrap its explicit test settings;
# normal curl/git can keep their native HTTPS-proxy support outside rl-env.
root = pathlib.Path("/opt/review-loop-tools")
(root / "rl-env").rename(root / "rl-env-direct")
wrapper = """#!/usr/bin/python3
import os
import sys
from urllib.parse import urlsplit, urlunsplit

env = os.environ.copy()
for key in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"):
    value = env.get(key)
    if not value:
        continue
    proxy = urlsplit(value)
    if proxy.scheme != "https":
        raise SystemExit("Reviewer command requires an HTTPS broker")
    if (proxy.hostname, proxy.port or 443) != BROKER_ENDPOINT:
        raise SystemExit("Reviewer broker endpoint changed; start a fresh worker")
    authority = proxy.netloc.rsplit("@", 1)
    credentials = authority[0] + "@" if len(authority) == 2 else ""
    env[key] = urlunsplit(("http", credentials + "127.0.0.1:18443", "", "", ""))
os.execve("/opt/review-loop-tools/rl-env-direct", ["rl-env", *sys.argv[1:]], env)
"""
wrapper = wrapper.replace("BROKER_ENDPOINT", repr((proxy.hostname, proxy.port or 443)))
(root / "rl-env").write_text(wrapper)
(root / "rl-env").chmod(0o755)
PY_RELAY
fi
rl-env mix deps.get
rl-env sh -c 'mix deps.unlock --unused && git diff --exit-code -- mix.lock'
rl-env sh -c 'mix ecto.create --quiet && mix ecto.migrate --quiet'
