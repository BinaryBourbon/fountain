import copy
from pathlib import Path
import re
import unittest

from gate import FULL_JOBS, JOBS, PROBES, validate


EVENTS = ("pull_request", "push", "merge_group")


def plan(event="pull_request", docs=False, touched=False, reuse=False):
    jobs = {job: {"result": "skipped", "outputs": {}} for job in JOBS}
    jobs["workflow-checks"]["result"] = "success"
    if "already-tested" in PROBES[event]:
        jobs["already-tested"] = {"result": "success", "outputs": {"skip": str(reuse).lower()}}
    if "changes" in PROBES[event]:
        jobs["changes"] = {"result": "success", "outputs": {
            "docs_only": str(docs).lower(), "docs_touched": str(touched).lower(),
            "cli_docs": "false", "tree": "a" * 40,
        }}
    if reuse:
        return jobs
    if docs:
        jobs["docs"]["result"] = "success"
    else:
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

    def test_every_event_the_workflow_triggers_on_is_a_plan(self):
        """A trigger the gate cannot validate fails every run of that event.

        The merge queue is the expensive version: an unsupported event fails
        `CI required`, and the queue reads that as the PR being broken and
        ejects it.
        """
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        triggers = workflow.split("\non:\n", 1)[1].split("\nconcurrency:", 1)[0]
        declared = set(re.findall(r"^  ([a-z_]+):$", triggers, re.M))
        self.assertEqual(declared, set(PROBES))

    def test_all_supported_plans(self):
        for event, options in [("pull_request", {}), ("pull_request", {"docs": True}),
                               ("pull_request", {"touched": True}), ("push", {}),
                               ("push", {"reuse": True}), ("merge_group", {}),
                               ("merge_group", {"docs": True}), ("merge_group", {"touched": True}),
                               ("merge_group", {"reuse": True})]:
            with self.subTest(event=event, options=options):
                validate(event, plan(event, **options))

    def test_every_required_job_rejects_failure_cancel_and_skip(self):
        for event, options in [("pull_request", {"touched": True}), ("pull_request", {"docs": True}),
                               ("push", {}), ("push", {"reuse": True}),
                               ("merge_group", {"touched": True}), ("merge_group", {"docs": True}),
                               ("merge_group", {"reuse": True})]:
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
        for event in EVENTS:
            for job in JOBS:
                jobs = plan(event)
                del jobs[job]
                with self.subTest(event=event, job=job):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)

    def test_missing_classification_or_tree_is_not_a_docs_skip(self):
        for event in ("pull_request", "merge_group"):
            for key in ("docs_only", "docs_touched", "cli_docs", "tree"):
                jobs = plan(event, docs=True)
                del jobs["changes"]["outputs"][key]
                with self.subTest(event=event, key=key):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)

    def test_missing_reuse_decision_fails(self):
        for event in ("push", "merge_group"):
            jobs = plan(event, reuse=True)
            jobs["already-tested"]["outputs"] = {}
            with self.subTest(event=event):
                with self.assertRaises(ValueError):
                    validate(event, jobs)

    def test_unexpected_failed_job_cannot_hide_on_docs_path(self):
        for event in ("pull_request", "merge_group"):
            jobs = plan(event, docs=True)
            jobs["test"]["result"] = "failure"
            with self.subTest(event=event):
                with self.assertRaises(ValueError):
                    validate(event, jobs)

    def test_a_merge_group_needs_both_probes(self):
        """Either probe alone would let the queue merge on half a decision."""
        for probe in ("already-tested", "changes"):
            jobs = plan("merge_group")
            jobs[probe] = {"result": "skipped", "outputs": {}}
            with self.subTest(probe=probe):
                with self.assertRaises(ValueError):
                    validate("merge_group", jobs)

    def test_unsupported_event_is_rejected(self):
        with self.assertRaises(ValueError):
            validate("workflow_dispatch", plan("pull_request"))
