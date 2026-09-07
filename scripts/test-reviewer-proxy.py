#!/usr/bin/env python3
"""Exercise the recipe's TLS relay with local certificates; needs socat/openssl."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
from unittest.mock import patch


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run():
    source = (Path(__file__).resolve().parents[1] / ".github/review/reviewer-setup.sh").read_text()
    bootstrap = source.split("python3 - <<'PY_RELAY'\n", 1)[1].split("\nPY_RELAY", 1)[0]
    servers = []
    state = {}
    with tempfile.TemporaryDirectory(prefix="reviewer-proxy-") as directory:
        root = Path(directory)
        tools = root / "tools"
        tools.mkdir()
        remote_port, relay_port = port(), port()
        try:
            for name, hostname in [("good", "localhost"), ("wrong", "wrong.invalid"), ("untrusted", "localhost")]:
                subprocess.run([
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(root / f"{name}.key"), "-out", str(root / f"{name}.crt"),
                    "-days", "1", "-subj", f"/CN={hostname}", "-addext", f"subjectAltName=DNS:{hostname}",
                ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ca = root / "trusted.pem"
            ca.write_bytes((root / "good.crt").read_bytes() + (root / "wrong.crt").read_bytes())
            wrapper = tools / "rl-env"
            wrapper.write_text('#!/usr/bin/python3\nimport os,json\nprint(json.dumps({k:os.environ.get(k) for k in ["HTTPS_PROXY","HTTP_PROXY","https_proxy","http_proxy"]}))\n')
            wrapper.chmod(0o755)
            bootstrap = bootstrap.replace("/opt/review-loop-tools", str(tools)).replace(
                "/etc/ssl/certs/ca-certificates.crt", str(ca)
            ).replace("18443", str(relay_port))
            env = {"PATH": os.environ["PATH"]}
            for key in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"):
                env[key] = f"https://fixture-user:fixture-password@localhost:{remote_port}"

            def serve(name):
                server = subprocess.Popen([
                    "openssl", "s_server", "-accept", str(remote_port), "-cert", str(root / f"{name}.crt"),
                    "-key", str(root / f"{name}.key"), "-www", "-quiet",
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                servers.append(server)
                for _ in range(50):
                    if server.poll() is not None:
                        raise AssertionError("TLS fixture exited before accepting connections")
                    try:
                        with socket.create_connection(("127.0.0.1", remote_port), timeout=.1):
                            return server
                    except OSError:
                        time.sleep(.02)
                raise AssertionError("TLS fixture did not become ready")

            def request():
                with socket.create_connection(("127.0.0.1", relay_port), timeout=3) as sock:
                    sock.sendall(b"GET / HTTP/1.0\r\n\r\n")
                    try:
                        return sock.recv(16384)
                    except ConnectionResetError:
                        return b""

            server = serve("good")
            with patch.dict(os.environ, env, clear=True):
                exec(compile(bootstrap, "reviewer-setup.sh:PY_RELAY", "exec"), state)
            result = json.loads(subprocess.check_output([str(wrapper)], env=env))
            expected = f"http://fixture-user:fixture-password@127.0.0.1:{relay_port}"
            assert all(value == expected for value in result.values())
            assert "fixture-password" not in wrapper.read_text()
            assert b"HTTP/1.0 200" in request(), "trusted TLS relay failed"
            print("PASS: trusted TLS and process-only credentials")
            server.terminate()
            server.wait(timeout=5)
            for name in ("wrong", "untrusted"):
                server = serve(name)
                assert request() == b"", f"{name} certificate accepted"
                print(f"PASS: {name} certificate rejected")
                server.terminate()
                server.wait(timeout=5)
            env["HTTPS_PROXY"] = f"https://fixture-user:fixture-password@wrong.invalid:{remote_port}"
            result = subprocess.run([str(wrapper)], env=env, capture_output=True)
            assert result.returncode and b"endpoint changed" in result.stderr
            print("PASS: changed broker endpoint rejected")
        finally:
            relay = state.get("relay")
            if relay is not None and relay.poll() is None:
                os.killpg(relay.pid, signal.SIGTERM)
                relay.wait(timeout=5)
            for server in servers:
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=5)


if __name__ == "__main__":
    run()
