#!/usr/bin/env python3
"""Validate the complete CI plan before publishing the stable required check."""

import argparse
import json
import os
import re
from pathlib import Path


FULL_JOBS = {
    "test", "coverage", "elixir-static", "release-and-contract", "cli-plugins", "typescript-sdk",
    "elixir-sdk", "python-sdk", "swift-sdk", "core-distribution", "compose-fresh-clone", "compose-pinned-image-boot",
}
SDK_JOBS = {"elixir-sdk", "python-sdk", "typescript-sdk", "swift-sdk"}
SDK_GATE_JOBS = SDK_JOBS | {"already-tested", "changes"}
JOBS = FULL_JOBS | {"already-tested", "changes", "workflow-checks", "docs", "docs-prose", "sdk-checks"}

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
    tree = outputs.get("tree")
    if not isinstance(tree, str) or not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise ValueError("checkout tree is missing or invalid")
    selected = set()
    for job in SDK_JOBS:
        value = outputs.get("sdk_" + job.removesuffix("-sdk"))
        if value not in ("true", "false"):
            raise ValueError("SDK classification is missing or invalid")
        if value == "true":
            selected.add(job)
    return outputs["docs_only"] == "true", outputs["docs_touched"] == "true", selected


def _expected_plan(event, needs, jobs):
    if event not in PROBES:
        raise ValueError(f"unsupported CI event: {event}")
    if set(needs) != jobs:
        raise ValueError(f"CI dependencies differ: missing={jobs - set(needs)}, extra={set(needs) - jobs}")

    expected = dict.fromkeys(jobs, "skipped")
    for probe in PROBES[event]:
        expected[probe] = "success"

    reuse = _reuse(needs) if "already-tested" in PROBES[event] else False
    docs_only, docs_touched, sdks = (
        _classification(needs) if "changes" in PROBES[event] else (False, True, SDK_JOBS)
    )
    # SDK docs can select a language even when the server plan is docs-only.
    if not reuse:
        expected.update(dict.fromkeys(sdks, "success"))

    return expected, not reuse and not docs_only, docs_only, docs_touched, reuse


def validate(event, needs):
    expected, full, docs_only, docs_touched, reuse = _expected_plan(event, needs, JOBS)
    expected["workflow-checks"] = "success"
    expected["sdk-checks"] = "success"
    # Docs-only still owes docs. Reused trees skip the workload jobs, while
    # both aggregate checks validate that the selected plan was followed.
    if docs_only and not reuse:
        expected["docs"] = "success"
    if full:
        expected.update(dict.fromkeys(FULL_JOBS - SDK_JOBS, "success"))
    if full and docs_touched:
        expected["docs-prose"] = "success"
    _check_results(needs, expected)


def validate_sdks(event, needs):
    expected, _, _, _, _ = _expected_plan(event, needs, SDK_GATE_JOBS)
    _check_results(needs, expected)


def _check_results(needs, expected):
    errors = [f"{job}: expected {result}, got {needs[job].get('result')}"
              for job, result in sorted(expected.items()) if needs[job].get("result") != result]
    if errors:
        raise ValueError("\n".join(errors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", action="store_true", help="validate only the SDK job plan")
    args = parser.parse_args()
    needs = json.loads(os.environ["CI_NEEDS"])
    event = os.environ["GITHUB_EVENT_NAME"]
    if args.sdk:
        validate_sdks(event, needs)
        print("Every SDK job required by this CI plan passed.")
    else:
        validate(event, needs)
        # Only complete CI may publish evidence for main's tested-tree shortcut.
        if event != "push":
            Path("tested-tree.txt").write_text(needs["changes"]["outputs"]["tree"] + "\n")
        print("Every job required by this CI plan passed.")
