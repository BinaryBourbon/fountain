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
