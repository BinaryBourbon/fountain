#!/usr/bin/env python3
"""Bootstrap must ignore PR-local modules; project commands use the checkout."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1] / ".github/review/reviewer-setup.sh"
with tempfile.TemporaryDirectory(prefix="reviewer-cwd-") as directory:
    root = Path(directory)
    checkout = root / "checkout"
    checkout.mkdir()
    bin_dir = root / "bin"
    bin_dir.mkdir()
    bootstrap = checkout / ".github/review/setup.sh"
    bootstrap.parent.mkdir(parents=True)
    bootstrap.write_text('set -eu\ntest "$PWD" = /\npython3 -c "import json"\nprintf "bootstrap-ok\\n" > "$REVIEWER_CWD_EVIDENCE"\n')
    (checkout / "json.py").write_text('raise RuntimeError("PR module executed during bootstrap")\n')
    command = bin_dir / "rl-env"
    command.write_text('#!/bin/sh\nset -eu\ntest "$PWD" = "$REVIEW_LOOP_WORKSPACE"\nprintf "workspace-command-ok\\n" >> "$REVIEWER_CWD_EVIDENCE"\n')
    command.chmod(0o755)
    def git(*args):
        return subprocess.check_output([
            "git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
            "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", *args,
        ], cwd=checkout, stderr=subprocess.DEVNULL, text=True).strip()
    git("init")
    git("add", ".")
    git("commit", "-m", "fixture")
    revision = git("rev-parse", "HEAD")
    evidence = root / "evidence"
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "HTTPS_PROXY": "",
           "REVIEW_LOOP_BASE": revision, "REVIEW_LOOP_HEAD": revision,
           "REVIEW_LOOP_WORKSPACE": str(checkout), "REVIEWER_CWD_EVIDENCE": str(evidence)}
    subprocess.run(["sh", str(source)], cwd=checkout, env=env, check=True)
    assert evidence.read_text().splitlines() == ["bootstrap-ok"] + ["workspace-command-ok"] * 3
    print("PASS: neutral bootstrap ignores PR Python module; project commands enter the checkout")
