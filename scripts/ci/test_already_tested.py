import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("already-tested.sh").resolve()
QUEUE_REF = "refs/heads/gh-readonly-queue/main/pr-1234-" + "d" * 40

# One fake `gh`. MODE removes a single piece of evidence so each test can show
# what the probe does without it; the run ids distinguish which lookup answered.
GH = '''#!/bin/sh
case "$*" in
  *'/pulls '*)
    [ "$MODE" = api-error ] && exit 1
    [ "$MODE" = no-pr ] || echo "1234 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *'/pulls/'*)
    [ "$MODE" = api-error ] && exit 1
    [ "$MODE" = no-pr ] || echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  *'runs?head_sha='*)
    [ "$MODE" = no-run ] && exit 0
    [ "$MODE" = queue-only ] || echo 123 ;;
  *'runs?event=merge_group'*)
    [ "$MODE" = no-run ] && exit 0
    echo 456 ;;
  'run download '*)
    [ "$MODE" = no-artifact ] && exit 1
    while [ "$1" != --dir ]; do shift; done
    printf '%s' "$PROOF" > "$2/tested-tree.txt" ;;
  *) exit 2 ;;
esac
'''


class TestedTreeTest(unittest.TestCase):
    def probe(self, mode, proof, event="push"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {
                "git": "#!/bin/sh\nprintf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
                "gh": GH,
            }.items():
                path = root / name
                path.write_text(body)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", MODE=mode, PROOF=proof,
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"),
                       GITHUB_REPOSITORY="owner/repo", GITHUB_SHA="c" * 40,
                       GITHUB_EVENT_NAME=event, GITHUB_REF=QUEUE_REF)
            subprocess.run(["bash", str(SCRIPT)], env=env, check=True, capture_output=True)
            return (root / "output").read_text().splitlines()[-1]

    def test_matching_checkout_tree_reuses_ci(self):
        for event in ("push", "merge_group"):
            with self.subTest(event=event):
                self.assertEqual(self.probe("match", "a" * 40 + "\n", event), "skip=true")

    def test_different_merge_tree_cannot_reuse_a_successful_head(self):
        for event in ("push", "merge_group"):
            with self.subTest(event=event):
                self.assertEqual(self.probe("match", "b" * 40 + "\n", event), "skip=false")

    def test_missing_evidence_falls_back_to_full_ci(self):
        for event in ("push", "merge_group"):
            for mode in ("api-error", "no-pr", "no-run", "no-artifact"):
                with self.subTest(event=event, mode=mode):
                    self.assertEqual(self.probe(mode, "a" * 40 + "\n", event), "skip=false")

    def test_malformed_artifact_is_not_executed_or_accepted(self):
        for proof in ("", "a" * 40, "a" * 40 + "\nextra\n", "$(exit 0)\n"):
            with self.subTest(proof=proof):
                self.assertEqual(self.probe("match", proof), "skip=false")

    def test_main_reuses_the_queue_run_that_tested_the_merge(self):
        """The whole point of queueing: main's push is already proven.

        `queue-only` answers nothing for the PR head, so a skip here can only
        have come from the `gh-readonly-queue/.../pr-1234-` lookup.
        """
        self.assertEqual(self.probe("queue-only", "a" * 40 + "\n", "push"), "skip=true")

    def test_a_queue_run_cannot_prove_itself_with_another_queue_run(self):
        """Inside the queue the merge_group run IS the decision being made.

        Reusing a sibling queue run would let a group skip the suite on the
        strength of a tree that belonged to a different group.
        """
        self.assertEqual(self.probe("queue-only", "a" * 40 + "\n", "merge_group"), "skip=false")
