#!/usr/bin/env python3
"""Validate the complete CI plan before publishing the stable required check."""

import json
import os
import re
from pathlib import Path


FULL_JOBS = {
    "test", "coverage", "elixir-static", "release-and-contract", "sdk-clients",
    "swift-sdk", "core-distribution", "compose-fresh-clone", "compose-pinned-image-boot",
}
JOBS = FULL_JOBS | {"already-tested", "changes", "workflow-checks", "docs", "docs-prose"}


def validate(event, needs):
    if event not in {"push", "pull_request"}:
        raise ValueError(f"unsupported CI event: {event}")
    if set(needs) != JOBS:
        raise ValueError(f"CI dependencies differ: missing={JOBS - set(needs)}, extra={set(needs) - JOBS}")

    expected = dict.fromkeys(JOBS, "skipped")
    expected["workflow-checks"] = "success"
    if event == "push":
        expected["already-tested"] = "success"
        skip = needs["already-tested"].get("outputs", {}).get("skip")
        if skip not in {"true", "false"}:
            raise ValueError("main's tested-tree probe did not make a decision")
        full = skip == "false"
        prose = full
    else:
        expected["changes"] = "success"
        outputs = needs["changes"].get("outputs", {})
        if any(outputs.get(key) not in {"true", "false"} for key in ("docs_only", "docs_touched", "cli_docs")):
            raise ValueError("PR change classification is missing or invalid")
        if not re.fullmatch(r"[0-9a-f]{40}", outputs.get("tree", "")):
            raise ValueError("PR checkout tree is missing or invalid")
        full = outputs["docs_only"] == "false"
        prose = full and outputs["docs_touched"] == "true"
        if not full:
            expected["docs"] = "success"

    if full:
        expected.update(dict.fromkeys(FULL_JOBS, "success"))
    if prose:
        expected["docs-prose"] = "success"
    errors = [f"{job}: expected {result}, got {needs[job].get('result')}"
              for job, result in sorted(expected.items()) if needs[job].get("result") != result]
    if errors:
        raise ValueError("\n".join(errors))


if __name__ == "__main__":
    needs = json.loads(os.environ["CI_NEEDS"])
    validate(os.environ["GITHUB_EVENT_NAME"], needs)
    if os.environ["GITHUB_EVENT_NAME"] == "pull_request":
        Path("tested-tree.txt").write_text(needs["changes"]["outputs"]["tree"] + "\n")
    print("Every job required by this CI plan passed.")
