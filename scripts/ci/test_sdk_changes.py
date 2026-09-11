import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from sdk_changes import LANGUAGES, OWNED_FILES, classify, from_git


SCRIPT = Path(__file__).with_name("sdk_changes.py").resolve()


class SDKChangesTest(unittest.TestCase):
    def test_sdk_sources_docs_and_owned_tooling(self):
        for language in LANGUAGES:
            for path in {f"sdk/{language}/src/client", f"sdk/{language}/README.md",
                         f"sdk/{language}/new-tool"} | OWNED_FILES[language]:
                with self.subTest(path=path):
                    self.assertEqual(classify([path]), {language})

    def test_public_contract_shared_fixtures_and_uncertainty_fan_out(self):
        for path in (
            "sdk/contract/contract.json", "sdk/contract/manifests/python.json",
            "sdk/conformance/scenarios/new.json", "scripts/sdk-contract/build.py",
            "apps/fountain/lib/fountain_web/schemas.ex",
            "apps/fountain/lib/fountain_web/router.ex",
            "apps/fountain/lib/fountain_web/controllers/api/agent_controller.ex",
            "apps/fountain/lib/fountain_web/plugs/auth.ex",
            "apps/fountain/lib/mix/tasks/openapi.export.ex",
            "apps/fountain/lib/fountain/agents.ex", "config/config.exs", "mix.lock",
            "ee/lib/fountain_web/controllers/api/credits_controller.ex",
            "apps/fountain_buzz/lib/fountain_buzz_web/router.ex",
            ".github/workflows/ci.yml", "scripts/ci/sdk_changes.py", "sdk/new-language/client",
            "new-directory/unknown", "README.md",
        ):
            with self.subTest(path=path):
                self.assertEqual(classify(["docs/index.md", path]), LANGUAGES)

    def test_unrelated_paths_and_mixed_sdk_changes(self):
        paths = ["docs/index.md", "decisions/0001-template.md", "assets/css/tokens.css",
                 "apps/fountain/lib/fountain_web/live/dashboard_live/index.ex",
                 "apps/fountain/lib/fountain_web/components/core_components.ex",
                 "apps/fountain/lib/fountain/telemetry_tick.ex",
                 "apps/fountain/test/fountain/agents_test.exs"]
        self.assertEqual(classify(paths), set())
        self.assertEqual(classify(paths + ["sdk/python/test.py", "sdk/swift/README.md"]),
                         {"python", "swift"})
        self.assertEqual(classify(["docs/sdk.md"]), {"typescript"})

    def test_empty_and_ambiguous_paths_select_all(self):
        self.assertEqual(classify([]), LANGUAGES)
        for path in ("", "/docs/index.md", "docs/../config/config.exs", "docs//index.md",
                     "docs/./index.md", "docs/file\nname", "docs/file\rname", "docs/file\x7f"):
            with self.subTest(path=path):
                self.assertEqual(classify([path]), LANGUAGES)

    def test_unreadable_diff_selects_all(self):
        for output in (b"", b"docs/index.md", b"docs/\xff\0"):
            with self.subTest(output=output), patch("sdk_changes.subprocess.run") as run:
                run.return_value.stdout = output
                self.assertEqual(from_git("a" * 40), LANGUAGES)
        with patch("sdk_changes.subprocess.run", side_effect=OSError):
            self.assertEqual(from_git("a" * 40), LANGUAGES)

    def test_actual_git_diff_handles_deletions_renames_and_output_safety(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            def write(path):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture\n")
            def commit():
                git("add", "-A")
                git("-c", "user.name=SDK test", "-c", "user.email=sdk@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            def selection(base):
                result = subprocess.check_output([sys.executable, str(SCRIPT), base], cwd=root).decode()
                values = dict(line.split("=") for line in result.splitlines())
                self.assertEqual(set(values), {f"sdk_{language}" for language in LANGUAGES})
                self.assertLessEqual(set(values.values()), {"true", "false"})
                return {language for language in LANGUAGES if values[f"sdk_{language}"] == "true"}
            git("init", "-q")
            write("sdk/python/client.py")
            base = commit()
            git("mv", "sdk/python/client.py", "sdk/python/renamed.py")
            commit()
            self.assertEqual(selection(base), {"python"})
            base = git("rev-parse", "HEAD")
            write("docs/index.md")
            git("mv", "sdk/python/renamed.py", "docs/renamed.py")
            commit()
            self.assertEqual(selection(base), {"python"})
            base = git("rev-parse", "HEAD")
            os.remove(root / "docs/index.md")
            commit()
            self.assertEqual(selection(base), set())
            base = git("rev-parse", "HEAD")
            write("docs/file\nsdk_python=false")
            commit()
            self.assertEqual(selection(base), LANGUAGES)
            for bad_base in ("", "--output=unsafe", "a" * 40, git("rev-parse", "HEAD")):
                with self.subTest(base=bad_base):
                    self.assertEqual(selection(bad_base), LANGUAGES)

    def test_workflow_exposes_decisions_from_the_classified_base(self):
        workflow = (SCRIPT.parents[2] / ".github/workflows/ci.yml").read_text()
        changes = workflow.split("\n  changes:\n", 1)[1].split("\n  test:\n", 1)[0]
        for language in LANGUAGES:
            self.assertIn(f"sdk_{language}: ${{{{ steps.sdks.outputs.sdk_{language} }}}}", changes)
        self.assertIn('echo "diff_base=${base:-}"', changes)
        self.assertIn("DIFF_BASE: ${{ steps.filter.outputs.diff_base }}", changes)
        self.assertIn('python3 scripts/ci/sdk_changes.py "$DIFF_BASE" >> "$GITHUB_OUTPUT"', changes)
