from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))

from verify_contract import check_contract  # noqa: E402


class ContractTests(unittest.TestCase):
    def test_contract(self) -> None:
        problems = check_contract()
        self.assertEqual(
            problems,
            [],
            "SDK contract problems:\n%s" % "\n\n".join(problems),
        )
