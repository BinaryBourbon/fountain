import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from gate import SDK_GATE_JOBS, SDK_JOBS, validate_sdks
from test_gate import plan


CASES = [
    ("workflow_dispatch", {}),
    ("pull_request", {}), ("pull_request", {"docs": True}),
    ("push", {}), ("push", {"reuse": True}),
    ("merge_group", {}), ("merge_group", {"docs": True}),
    ("merge_group", {"reuse": True}),
]


def sdk_plan(event, **options):
    return {name: state for name, state in plan(event, **options).items()
            if name in SDK_GATE_JOBS}


class SdkGateTest(unittest.TestCase):
    def test_workflow_reports_the_stable_check_even_when_legs_are_skipped(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  sdk-checks:\n", 1)[1].split("\n  gate:\n", 1)[0]
        self.assertIn("    name: SDK checks\n", job)
        self.assertIn("    if: ${{ always() }}\n", job)
        self.assertIn("run: python3 scripts/ci/gate.py --sdk", job)
        dependencies = job.split("    needs:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertEqual(set(re.findall(r"^      - (.*)$", dependencies, re.M)), SDK_GATE_JOBS)
        self.assertEqual(SDK_JOBS, {"elixir-sdk", "python-sdk", "typescript-sdk", "swift-sdk"})

    def test_full_docs_and_reused_plans_pass(self):
        for event, options in CASES:
            with self.subTest(event=event, options=options):
                validate_sdks(event, sdk_plan(event, **options))

    def test_no_failed_cancelled_missing_or_unexpectedly_skipped_result_passes(self):
        for event, options in CASES:
            original = sdk_plan(event, **options)
            for name, state in original.items():
                for result in ("success", "failure", "cancelled", "skipped", None):
                    if result == state["result"]:
                        continue
                    with self.subTest(event=event, options=options, job=name, result=result):
                        needs = copy.deepcopy(original)
                        needs[name]["result"] = result
                        with self.assertRaises(ValueError):
                            validate_sdks(event, needs)

    def test_missing_or_extra_dependencies_are_not_a_complete_sdk_plan(self):
        for event, options in CASES:
            for name in SDK_GATE_JOBS:
                needs = sdk_plan(event, **options)
                del needs[name]
                with self.assertRaises(ValueError):
                    validate_sdks(event, needs)
            needs = sdk_plan(event, **options)
            needs["unregistered-sdk"] = {"result": "success"}
            with self.assertRaises(ValueError):
                validate_sdks(event, needs)

    def test_invalid_probe_outputs_cannot_authorize_skipping_sdks(self):
        for event, options in CASES:
            original = sdk_plan(event, **options)
            for name in ("changes", "already-tested"):
                for key in original[name]["outputs"]:
                    for value in (None, "invalid"):
                        needs = copy.deepcopy(original)
                        needs[name]["outputs"][key] = value
                        with self.subTest(event=event, probe=name, key=key, value=value):
                            with self.assertRaises(ValueError):
                                validate_sdks(event, needs)
        with self.assertRaises(ValueError):
            validate_sdks("unknown_event", sdk_plan("pull_request"))

    def test_sdk_cli_never_publishes_whole_tree_reuse_evidence(self):
        script = Path(__file__).with_name("gate.py").resolve()
        for event, options in CASES:
            with tempfile.TemporaryDirectory() as workdir:
                env = dict(os.environ, GITHUB_EVENT_NAME=event,
                           CI_NEEDS=json.dumps(sdk_plan(event, **options)))
                result = subprocess.run([sys.executable, str(script), "--sdk"], cwd=workdir,
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((Path(workdir) / "tested-tree.txt").exists())

    def test_sdk_cli_exits_nonzero_for_a_failed_leg(self):
        needs = sdk_plan("pull_request")
        needs["typescript-sdk"]["result"] = "failure"
        script = Path(__file__).with_name("gate.py").resolve()
        with tempfile.TemporaryDirectory() as workdir:
            result = subprocess.run(
                [sys.executable, str(script), "--sdk"], cwd=workdir,
                env=dict(os.environ, GITHUB_EVENT_NAME="pull_request", CI_NEEDS=json.dumps(needs)),
                text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("typescript-sdk: expected success, got failure", result.stderr)
            self.assertFalse((Path(workdir) / "tested-tree.txt").exists())
