from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ElixirSDKMatrixTest(unittest.TestCase):
    def test_minimum_runtime_and_current_formatter_keep_complete_sdk_checks(self):
        project = (ROOT / "sdk/elixir/mix.exs").read_text()
        minimum = re.search(r'elixir: "~> ([0-9.]+)"', project)[1]
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  elixir-sdk:\n", 1)[1].split("\n  python-sdk:\n", 1)[0]
        pairs = re.findall(r'          - elixir: "([0-9.]+)"\n            otp: "([0-9.]+)"', job)
        self.assertTrue(any(version.startswith(minimum + ".") for version, _ in pairs))
        self.assertIn(("1.19.2", "28.3"), pairs)
        self.assertIn("fail-fast: false", job)
        self.assertIn("elixir-version: ${{ matrix.elixir }}", job)
        self.assertIn("otp-version: ${{ matrix.otp }}", job)
        self.assertIn("steps.beam.outputs.otp-version", job)
        self.assertIn("steps.beam.outputs.elixir-version", job)
        steps = dict(re.findall(r"      - name: ([^\n]+)\n(.*?)(?=      - (?:name:|uses:)|\Z)", job, re.S))
        self.assertIn("if: ${{ matrix.elixir == '1.19.2' }}", steps["Elixir SDK formatting"])
        self.assertIn("run: mix format --check-formatted", steps["Elixir SDK formatting"])
        for name in ("Elixir SDK dependencies", "Elixir SDK compile", "Elixir SDK tests",
                     "Elixir SDK documentation", "Elixir SDK package dry run",
                     "Elixir SDK contract", "Elixir SDK conformance"):
            self.assertNotIn("        if:", steps[name])
