import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from gate import FULL_JOBS, SDK_GATE_JOBS, SDK_JOBS, validate, validate_sdks
from test_gate import plan


ROOT = Path(__file__).resolve().parents[2]


class DispatchTest(unittest.TestCase):
    def test_actual_classifier_selects_full_ci_without_fetching_a_base(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  changes:\n", 1)[1].split("\n  test:\n", 1)[0]
        self.assertIn("|| github.event_name == 'workflow_dispatch' }}", job)
        script = job.split("        id: filter\n", 1)[1].split("        run: |\n", 1)[1]
        script = textwrap.dedent(script.split("\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_git = root / "git"
            fake_git.write_text('#!/bin/sh\ntouch "$GIT_CALLED"\nexit 97\n')
            fake_git.chmod(0o755)
            output = root / "outputs"
            result = subprocess.run(["bash", "-e", "-c", script], cwd=root, capture_output=True, text=True,
                                    env=dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch",
                                             GITHUB_OUTPUT=str(output), GITHUB_BASE_REF="",
                                             MERGE_GROUP_BASE_SHA="", GIT_CALLED=str(root / "called"),
                                             PATH=str(root) + os.pathsep + os.environ["PATH"]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "called").exists())
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values, {"diff_base": "", "docs_only": "false",
                                      "cli_docs": "false", "docs_touched": "true"})
            sdks = subprocess.check_output([sys.executable, str(ROOT / "scripts/ci/sdk_changes.py"),
                                            values["diff_base"]], cwd=root, text=True)
            self.assertEqual(set(sdks.splitlines()),
                             {"sdk_" + job.removesuffix("-sdk") + "=true" for job in SDK_JOBS})

    def test_both_gates_reject_partial_manual_plans(self):
        original = plan("workflow_dispatch")
        mutations = [("docs_only", "true"), ("docs_touched", "false")]
        mutations += [("sdk_" + job.removesuffix("-sdk"), "false") for job in SDK_JOBS]
        for key, value in mutations:
            needs = copy.deepcopy(original)
            needs["changes"]["outputs"][key] = value
            if key == "docs_only":
                for job in FULL_JOBS - SDK_JOBS:
                    needs[job]["result"] = "skipped"
                needs["docs"]["result"] = "success"
                needs["docs-prose"]["result"] = "skipped"
            elif key == "docs_touched":
                needs["docs-prose"]["result"] = "skipped"
            else:
                needs[key.removeprefix("sdk_") + "-sdk"]["result"] = "skipped"
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, "manual CI must select the complete plan"):
                    validate("workflow_dispatch", needs)
                with self.assertRaisesRegex(ValueError, "manual CI must select the complete plan"):
                    validate_sdks("workflow_dispatch", {name: state for name, state in needs.items()
                                                       if name in SDK_GATE_JOBS})

    def test_full_manual_gate_can_publish_tested_tree_evidence(self):
        needs = plan("workflow_dispatch")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/gate.py")], cwd=directory,
                                    capture_output=True, text=True,
                                    env=dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch",
                                             CI_NEEDS=json.dumps(needs)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(directory) / "tested-tree.txt").read_text(), "a" * 40 + "\n")
