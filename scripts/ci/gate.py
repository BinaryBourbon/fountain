#!/usr/bin/env python3
"""Validate the complete CI plan before publishing the stable required check."""

import json
import os
import re
from pathlib import Path


FULL_JOBS = {
    "test", "coverage", "elixir-static", "release-and-contract", "sdk-clients",
    "elixir-sdk", "python-sdk", "swift-sdk", "core-distribution", "compose-fresh-clone", "compose-pinned-image-boot",
}
JOBS = FULL_JOBS | {"already-tested", "changes", "workflow-checks", "docs", "docs-prose"}

# Which probes are expected to have run, per event. A merge group is the only
# plan that runs both: the queue classifies the diff like a PR *and* asks
# whether the tree it is about to test has already been tested.
PROBES = {
    "pull_request": {"changes"},
    "push": {"already-tested"},
    "merge_group": {"already-tested", "changes"},
}


def _reuse(needs):
    skip = needs["already-tested"].get("outputs", {}).get("skip")
    if skip not in {"true", "false"}:
        raise ValueError("the tested-tree probe did not make a decision")
    return skip == "true"


def _classification(needs):
    outputs = needs["changes"].get("outputs", {})
    if any(outputs.get(key) not in {"true", "false"} for key in ("docs_only", "docs_touched", "cli_docs")):
        raise ValueError("change classification is missing or invalid")
    if not re.fullmatch(r"[0-9a-f]{40}", outputs.get("tree", "")):
        raise ValueError("checkout tree is missing or invalid")
    return outputs["docs_only"] == "true", outputs["docs_touched"] == "true"


def validate(event, needs):
    if event not in PROBES:
        raise ValueError(f"unsupported CI event: {event}")
    if set(needs) != JOBS:
        raise ValueError(f"CI dependencies differ: missing={JOBS - set(needs)}, extra={set(needs) - JOBS}")

    expected = dict.fromkeys(JOBS, "skipped")
    expected["workflow-checks"] = "success"
    for probe in PROBES[event]:
        expected[probe] = "success"

    reuse = _reuse(needs) if "already-tested" in PROBES[event] else False
    docs_only, docs_touched = _classification(needs) if "changes" in PROBES[event] else (False, True)

    full = not reuse and not docs_only
    # A docs-only plan still owes the docs job; a reused tree owes nothing,
    # because the identical tree already passed every gate this plan names.
    if docs_only and not reuse:
        expected["docs"] = "success"
    if full:
        expected.update(dict.fromkeys(FULL_JOBS, "success"))
    if full and docs_touched:
        expected["docs-prose"] = "success"
    errors = [f"{job}: expected {result}, got {needs[job].get('result')}"
              for job, result in sorted(expected.items()) if needs[job].get("result") != result]
    if errors:
        raise ValueError("\n".join(errors))


if __name__ == "__main__":
    needs = json.loads(os.environ["CI_NEEDS"])
    event = os.environ["GITHUB_EVENT_NAME"]
    validate(event, needs)
    # Main is the only event that consumes evidence rather than publishing it.
    if event != "push":
        Path("tested-tree.txt").write_text(needs["changes"]["outputs"]["tree"] + "\n")
    print("Every job required by this CI plan passed.")
