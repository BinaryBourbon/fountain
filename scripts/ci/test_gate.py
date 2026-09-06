import copy
from pathlib import Path
import re
import unittest

from gate import FULL_JOBS, JOBS, validate


def plan(event="pull_request", docs=False, touched=False, reuse=False):
    jobs = {job: {"result": "skipped", "outputs": {}} for job in JOBS}
    jobs["workflow-checks"]["result"] = "success"
    if event == "push":
        jobs["already-tested"] = {"result": "success", "outputs": {"skip": str(reuse).lower()}}
    else:
        jobs["changes"] = {"result": "success", "outputs": {
            "docs_only": str(docs).lower(), "docs_touched": str(touched).lower(),
            "cli_docs": "false", "tree": "a" * 40,
        }}
    if docs:
        jobs["docs"]["result"] = "success"
    elif not reuse:
        for job in FULL_JOBS:
            jobs[job]["result"] = "success"
        if touched or event == "push":
            jobs["docs-prose"]["result"] = "success"
    return jobs


class GateTest(unittest.TestCase):
    def test_workflow_and_gate_cover_the_same_jobs(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        jobs = set(re.findall(r"^  ([a-z][a-z0-9_-]*):$", workflow.split("\njobs:\n", 1)[1], re.M))
        self.assertEqual(jobs - {"gate"}, JOBS)
        gate = workflow.split("\n  gate:\n", 1)[1]
        dependencies = gate.split("    needs:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertEqual(set(re.findall(r"^      - (.*)$", dependencies, re.M)), JOBS)

    def test_all_supported_plans(self):
        for event, options in [("pull_request", {}), ("pull_request", {"docs": True}),
                               ("pull_request", {"touched": True}), ("push", {}),
                               ("push", {"reuse": True})]:
            with self.subTest(event=event, options=options):
                validate(event, plan(event, **options))

    def test_every_required_job_rejects_failure_cancel_and_skip(self):
        for event, options in [("pull_request", {"touched": True}), ("pull_request", {"docs": True}),
                               ("push", {}), ("push", {"reuse": True})]:
            original = plan(event, **options)
            for job, state in original.items():
                if state["result"] != "success":
                    continue
                for result in ("failure", "cancelled", "skipped", None):
                    with self.subTest(event=event, options=options, job=job, result=result):
                        jobs = copy.deepcopy(original)
                        jobs[job]["result"] = result
                        with self.assertRaises(ValueError):
                            validate(event, jobs)

    def test_missing_job_is_not_a_pass(self):
        for job in JOBS:
            jobs = plan()
            del jobs[job]
            with self.assertRaises(ValueError):
                validate("pull_request", jobs)

    def test_missing_classification_or_tree_is_not_a_docs_skip(self):
        for key in ("docs_only", "docs_touched", "cli_docs", "tree"):
            jobs = plan(docs=True)
            del jobs["changes"]["outputs"][key]
            with self.assertRaises(ValueError):
                validate("pull_request", jobs)

    def test_missing_reuse_decision_fails(self):
        jobs = plan("push", reuse=True)
        jobs["already-tested"]["outputs"] = {}
        with self.assertRaises(ValueError):
            validate("push", jobs)

    def test_unexpected_failed_job_cannot_hide_on_docs_path(self):
        jobs = plan(docs=True)
        jobs["test"]["result"] = "failure"
        with self.assertRaises(ValueError):
            validate("pull_request", jobs)
