# Reviewer workspace

`reviewer-setup.sh` prepares the exact PR checkout using the verifier bootstrap
from `REVIEW_LOOP_BASE`, then installs locked Hex dependencies and migrates a
local test database. Review Loop loads this script from the approved base and
bounds setup to 15 minutes. A changed tracked file or failed setup stops review.

Run diagnostics through `rl-env`. Setup success is not a passing test result;
independent service verification still decides whether the revision passes.

Hex 2.5.1 passes only a proxy host/port to Erlang httpc, so it cannot directly
use Fountain's HTTPS proxy. The recipe starts a loopback-only socat relay and
wraps `rl-env` to use it. The remote connection validates the broker's certificate
chain and hostname; authentication stays in process environments. The relay and
database belong to this ephemeral worker and end when it is deleted.

Test the relay with `python3 scripts/test-reviewer-proxy.py` on Linux with Python 3,
OpenSSL, and socat installed. It executes the recipe's relay code using temporary
paths and local certificates, covering valid TLS, wrong hostnames, untrusted
issuers, changed endpoints, and credential placement. It needs no provider keys.
