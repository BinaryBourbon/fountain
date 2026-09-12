from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


GATE = Path(__file__).resolve().parents[1] / "conflict-markers.py"


class ConflictMarkersTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "--quiet")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True)

    def scan(self):
        return subprocess.run([sys.executable, str(GATE)], cwd=self.root,
                              capture_output=True, text=True)

    def test_each_marker_is_rejected_in_tracked_files_of_any_type(self):
        for marker in ("<" * 7 + " HEAD", "=" * 7, ">" * 7 + " theirs",
                       "|" * 7 + " base"):
            for name in ("CHANGELOG.md", "fixture.json", ".env.example", "extension docs.md"):
                with self.subTest(marker=marker, name=name):
                    path = self.root / name
                    path.write_text("before\n" + marker + "\nafter\n")
                    self.git("add", "--", name)
                    result = self.scan()
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(f"{name}:2:", result.stdout)
                    self.git("rm", "--cached", "--", name)
                    path.unlink()

    def test_reads_working_tree_and_ignores_untracked_files(self):
        path = self.root / "tracked.md"
        path.write_text("clean\n")
        self.git("add", "tracked.md")
        path.write_text(">" * 7 + " theirs\n")
        self.assertEqual(self.scan().returncode, 1)
        path.write_text("clean\n")
        (self.root / "scratch.md").write_text("<" * 7 + " HEAD\n")
        self.assertEqual(self.scan().returncode, 0)

    def test_inline_examples_and_binary_files_do_not_match(self):
        (self.root / "guide.md").write_text('Example: ' + '>' * 7 + ' theirs\n' +
                                           'pattern = "' + '<' * 7 + '"\n' + '=' * 80 + '\n')
        (self.root / "image.bin").write_bytes(b"\0\n" + b">" * 7 + b" theirs\n")
        self.git("add", ".")
        self.assertEqual(self.scan().returncode, 0)

    def test_missing_repository_fails_closed(self):
        with tempfile.TemporaryDirectory() as other:
            result = subprocess.run([sys.executable, str(GATE)], cwd=other,
                                    capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tree was not checked", result.stderr)


if __name__ == "__main__":
    unittest.main()
