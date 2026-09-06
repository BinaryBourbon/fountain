import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("already-tested.sh").resolve()


class TestedTreeTest(unittest.TestCase):
    def probe(self, mode, proof):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {
                "git": "#!/bin/sh\nprintf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
                "gh": '''#!/bin/sh
case "$*" in
  *'/pulls '*)
    [ "$MODE" = api-error ] && exit 1
    [ "$MODE" = no-pr ] || echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  *'/actions/workflows/ci.yml/runs?'*)
    [ "$MODE" = no-run ] || echo 123 ;;
  'run download '*)
    [ "$MODE" = no-artifact ] && exit 1
    while [ "$1" != --dir ]; do shift; done
    printf '%s' "$PROOF" > "$2/tested-tree.txt" ;;
  *) exit 2 ;;
esac
''',
            }.items():
                path = root / name
                path.write_text(body)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", MODE=mode, PROOF=proof,
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"),
                       GITHUB_REPOSITORY="owner/repo", GITHUB_SHA="c" * 40)
            subprocess.run(["bash", str(SCRIPT)], env=env, check=True, capture_output=True)
            return (root / "output").read_text().splitlines()[-1]

    def test_matching_checkout_tree_reuses_ci(self):
        self.assertEqual(self.probe("match", "a" * 40 + "\n"), "skip=true")

    def test_different_merge_tree_cannot_reuse_a_successful_head(self):
        self.assertEqual(self.probe("match", "b" * 40 + "\n"), "skip=false")

    def test_missing_evidence_falls_back_to_full_ci(self):
        for mode in ("api-error", "no-pr", "no-run", "no-artifact"):
            with self.subTest(mode=mode):
                self.assertEqual(self.probe(mode, "a" * 40 + "\n"), "skip=false")

    def test_malformed_artifact_is_not_executed_or_accepted(self):
        for proof in ("", "a" * 40, "a" * 40 + "\nextra\n", "$(exit 0)\n"):
            with self.subTest(proof=proof):
                self.assertEqual(self.probe("match", proof), "skip=false")
