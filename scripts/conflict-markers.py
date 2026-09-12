#!/usr/bin/env python3
"""Reject unresolved conflict markers in tracked text files in the working tree."""

import subprocess
import sys


def main():
    # Match complete marker tokens, including diff3's ancestor marker. Keeping
    # the expression inside a string avoids matching this gate or its tests.
    result = subprocess.run([
        "git", "grep", "--no-color", "-I", "-n", "-E",
        r"^(<{7}|={7}|>{7}|\|{7})([[:space:]]|$)", "--", ".",
    ], check=False)
    if result.returncode == 1:
        print("Conflict markers: tracked text files are clean.")
        return 0
    if result.returncode == 0:
        print("Resolve the conflict markers listed above before committing.", file=sys.stderr)
        return 1
    print("Conflict-marker scan failed; the tree was not checked.", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
