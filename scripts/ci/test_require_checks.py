import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("require_checks", Path(__file__).with_name("require-checks.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RequiredChecksTest(unittest.TestCase):
    def current(self):
        return {"name": "Main", "target": "branch", "enforcement": "active", "id": 123,
                "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
                "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
                "rules": [{"type": "deletion"}, {"type": "pull_request", "parameters": {
                    "required_approving_review_count": 1}}]}

    def test_preserves_existing_rules_and_bypasses(self):
        current = self.current()
        result = module.updated_ruleset(current)
        self.assertEqual(result["rules"][:-1], current["rules"])
        self.assertEqual(result["bypass_actors"], current["bypass_actors"])
        self.assertEqual(result["conditions"], current["conditions"])
        self.assertEqual(len(current["rules"]), 2)
        self.assertNotIn("id", result)
        self.assertTrue(result["rules"][-1]["parameters"]["strict_required_status_checks_policy"])

    def test_idempotent_and_preserves_other_status_checks(self):
        current = self.current()
        current["rules"].append({"type": "required_status_checks", "parameters": {
            "strict_required_status_checks_policy": False,
            "required_status_checks": [{"context": "existing", "integration_id": 42}],
        }})
        result = module.updated_ruleset(current)
        self.assertEqual(module.updated_ruleset(result), result)
        params = result["rules"][-1]["parameters"]
        self.assertFalse(params["strict_required_status_checks_policy"])
        self.assertEqual(params["required_status_checks"], [
            {"context": "existing", "integration_id": 42},
            {"context": "CI required", "integration_id": 15368},
            {"context": "Detect secrets", "integration_id": 15368},
        ])

    def test_merge_queue_is_opt_in(self):
        result = module.updated_ruleset(self.current())
        self.assertEqual([r["type"] for r in result["rules"] if r["type"] == "merge_queue"], [])
        self.assertTrue(result["rules"][-1]["parameters"]["strict_required_status_checks_policy"])

    def test_merge_queue_adds_the_rule_and_drops_the_up_to_date_requirement(self):
        result = module.updated_ruleset(self.current(), merge_queue=True)
        queue = next(r for r in result["rules"] if r["type"] == "merge_queue")
        self.assertEqual(queue["parameters"], module.MERGE_QUEUE)
        checks = next(r for r in result["rules"] if r["type"] == "required_status_checks")
        self.assertFalse(checks["parameters"]["strict_required_status_checks_policy"])

    def test_merge_queue_leaves_the_review_requirement_alone(self):
        """Turning the queue on must not quietly relax who has to read a PR.

        The queue decides whether a tree builds. Whether a human looked at it
        is a separate gate, and enabling one is not a reason to drop the other.
        """
        for merge_queue in (False, True):
            result = module.updated_ruleset(self.current(), merge_queue=merge_queue)
            review = next(r for r in result["rules"] if r["type"] == "pull_request")
            with self.subTest(merge_queue=merge_queue):
                self.assertEqual(review["parameters"], next(
                    r for r in self.current()["rules"] if r["type"] == "pull_request")["parameters"])

    def test_merge_queue_is_idempotent_and_keeps_required_checks(self):
        once = module.updated_ruleset(self.current(), merge_queue=True)
        self.assertEqual(module.updated_ruleset(once, merge_queue=True), once)
        contexts = [c["context"] for c in
                    next(r for r in once["rules"] if r["type"] == "required_status_checks")
                    ["parameters"]["required_status_checks"]]
        self.assertEqual(contexts, ["CI required", "Detect secrets"])

    def test_the_queue_cannot_outrun_the_free_plan_job_ceiling(self):
        """One full CI run has 24 jobs; the documented concurrency limit is 20.

        Building more than one group at a time cannot run them in parallel; it
        only starves every open PR of runners.
        """
        self.assertEqual(module.MERGE_QUEUE["max_entries_to_build"], 1)
        self.assertGreater(module.MERGE_QUEUE["max_entries_to_merge"], 1)
        self.assertEqual(module.MERGE_QUEUE["grouping_strategy"], "ALLGREEN")
