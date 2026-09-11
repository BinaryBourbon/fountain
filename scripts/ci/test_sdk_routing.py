import copy
import itertools
from pathlib import Path
import re
import unittest

from gate import SDK_GATE_JOBS, SDK_JOBS, validate, validate_sdks
from sdk_changes import classify
from test_gate import plan


class SDKRoutingTest(unittest.TestCase):
    def check_both(self, event, needs):
        validate(event, needs)
        validate_sdks(event, {name: state for name, state in needs.items() if name in SDK_GATE_JOBS})

    def reject_both(self, event, needs):
        with self.assertRaises(ValueError):
            validate(event, needs)
        with self.assertRaises(ValueError):
            validate_sdks(event, {name: state for name, state in needs.items() if name in SDK_GATE_JOBS})

    def test_every_sdk_subset_on_code_docs_and_reused_plans(self):
        for event, docs, reuse, flags in itertools.product(
                ("pull_request", "merge_group"), (False, True), (False, True),
                itertools.product((False, True), repeat=4)):
            if event == "pull_request" and reuse:
                continue
            selected = {job for job, flag in zip(sorted(SDK_JOBS), flags) if flag}
            with self.subTest(event=event, docs=docs, reuse=reuse, selected=selected):
                original = plan(event, docs=docs, reuse=reuse, sdks=selected)
                self.check_both(event, original)
                for job in SDK_JOBS:
                    for result in ("success", "failure", "cancelled", "skipped", None):
                        if result == original[job]["result"]:
                            continue
                        needs = copy.deepcopy(original)
                        needs[job]["result"] = result
                        self.reject_both(event, needs)

    def test_missing_or_invalid_sdk_decisions_fail_even_for_reused_trees(self):
        for event, docs, reuse, job, value in itertools.product(
                ("pull_request", "merge_group"), (False, True), (False, True), SDK_JOBS,
                (None, "", "TRUE", "invalid", True, False, 0, [], {})):
            if event == "pull_request" and reuse:
                continue
            needs = plan(event, docs=docs, reuse=reuse)
            key = "sdk_" + job.removesuffix("-sdk")
            if value is None:
                del needs["changes"]["outputs"][key]
            else:
                needs["changes"]["outputs"][key] = value
            with self.subTest(event=event, docs=docs, reuse=reuse, job=job, value=value):
                self.reject_both(event, needs)

    def test_classifier_decisions_select_jobs_in_both_gates(self):
        cases = [(["sdk/python/src/fountain/http.py"], False, {"python-sdk"}),
                 (["docs/swift-sdk.md"], True, {"swift-sdk"}),
                 (["docs/index.md"], True, set()),
                 (["assets/css/tokens.css"], False, set()),
                 (["apps/fountain/lib/fountain/telemetry.ex"], False, set()),
                 (["sdk/conformance/matrix.json"], False, SDK_JOBS),
                 (["apps/fountain/lib/fountain_web/router.ex"], False, SDK_JOBS),
                 (["unregistered/path"], False, SDK_JOBS)]
        for paths, docs, expected in cases:
            selected = {language + "-sdk" for language in classify(paths)}
            self.assertEqual(selected, expected)
            for event in ("pull_request", "merge_group"):
                self.check_both(event, plan(event, docs=docs, sdks=selected))

    def test_main_still_requires_all_sdks_unless_the_tree_was_tested(self):
        self.check_both("push", plan("push"))
        self.check_both("push", plan("push", reuse=True))
        for job in SDK_JOBS:
            needs = plan("push")
            needs[job]["result"] = "skipped"
            self.reject_both("push", needs)

    def test_job_conditions_match_the_selection_and_preserve_contract_generation(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)",
                               workflow.split("\njobs:\n", 1)[1], re.M | re.S))
        for job in SDK_JOBS:
            language = job.removesuffix("-sdk")
            condition = re.search(r"^    if: (.*?)(?=\n\n)", jobs[job], re.M | re.S)[1]
            self.assertEqual(condition, "${{ !cancelled() && needs.already-tested.outputs.skip != 'true'\n"
                             f"         && needs.changes.outputs.sdk_{language} != 'false' }}}}")
            self.assertIn("needs: [already-tested, changes]", jobs[job])
        release = jobs["release-and-contract"]
        steps = dict(re.findall(r"      - name: ([^\n]+)\n(.*?)(?=      - (?:name:|uses:)|\Z)", release, re.S))
        condition = "        if: ${{ needs.changes.outputs.sdk_typescript != 'false' }}\n"
        for name in ("Set up Node", "SDK install", "SDK types match the spec"):
            self.assertIn(condition, steps[name])
        self.assertEqual(release.count(condition), 3)
        for name in ("Validate OpenAPI spec", "SDK wire contract is current"):
            self.assertNotIn("        if:", steps[name])
        self.assertIn("run: scripts/sdk-contract/build.sh --check", steps["SDK wire contract is current"])
