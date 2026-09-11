from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PythonSDKMatrixTest(unittest.TestCase):
    def test_supported_runtime_boundaries_run_all_existing_checks(self):
        metadata = (ROOT / "sdk/python/pyproject.toml").read_text()
        minimum = re.search(r'requires-python = ">=([0-9.]+)"', metadata)[1]
        declared = re.findall(r'Programming Language :: Python :: ([0-9]+\.[0-9]+)"', metadata)
        newest = max(declared, key=lambda version: tuple(map(int, version.split("."))))
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  python-sdk:\n", 1)[1].split("\n  typescript-sdk:\n", 1)[0]
        versions = re.findall(r'"([0-9.]+)"', re.search(r"        python: \[(.*)\]", job)[1])
        self.assertIn(minimum, versions)
        self.assertIn(newest, versions)
        self.assertIn("fail-fast: false", job)
        self.assertIn("name: Python SDK (${{ matrix.python }})", job)
        self.assertIn("python-version: ${{ matrix.python }}", job)
        self.assertLess(job.index("name: Set up Python"), job.index("python sdk/conformance/lint.py"))
        for command in ("python sdk/conformance/lint.py",
                        "python -m unittest discover -s sdk/python/tests -v",
                        "python -m compileall -q sdk/python/src sdk/python/scripts",
                        "python scripts/verify_contract.py",
                        'python -m unittest discover -s tests -p "test_conformance.py" -v'):
            self.assertIn("run: " + command, job)
        # No step-level condition can drop a check on the minimum runtime.
        self.assertNotIn("        if:", job)
