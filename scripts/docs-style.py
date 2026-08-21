#!/usr/bin/env python3
"""Enforce the docs style sheet on docs/**/*.md.

Three rules, all from docs-redesign/06-voice-and-style.md:

  1. No em or en dashes. An em dash is a hinge that lets a sentence continue
     after it has finished, and it is where explanation hides. Removing it
     forces the writer to choose a table row, a parenthesis or a full stop.
  2. Colons do not introduce lists. A colon makes the lead-in a fragment, and
     a fragment asserts nothing that can be checked against the code. Ending
     it with a full stop forces a complete claim.
  3. A small forbidden-word list. "simply" and "just" tell a stuck reader the
     thing they are stuck on is easy; "coming soon" describes unbuilt
     behaviour as if it existed, which CLAUDE.md already forbids.

Code fences and inline code spans are exempt, because they quote the world
rather than describe it.

THE RATCHET. Files listed in scripts/docs-style-allow.txt are skipped. That
list is the pre-existing backlog (#911) and is only ever meant to shrink. A
file NOT on the list is checked, so anything new is covered by default and
the cleanup can land page by page without leaving CI red in between.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ALLOW = ROOT / "scripts" / "docs-style-allow.txt"

FORBIDDEN = ["simply", "coming soon", "obviously"]
LIST_ITEM = re.compile(r"^\s*(?:[-*+]\s|\d+\.\s)")


def load_allowlist():
    if not ALLOW.exists():
        return set()
    out = set()
    for line in ALLOW.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


def strip_code(lines):
    """Blank out fenced blocks and inline code spans, keeping line numbers."""
    out = []
    in_fence = False
    for line in lines:
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append("")
            continue
        if in_fence or line.startswith("    ") and not LIST_ITEM.match(line):
            out.append("")
            continue
        out.append(re.sub(r"`[^`]*`", "", line))
    return out


def check(path, rel):
    raw = path.read_text().splitlines()
    text = strip_code(raw)
    problems = []

    for i, line in enumerate(text, 1):
        for ch, name in (("—", "em dash"), ("–", "en dash")):
            if ch in line:
                problems.append((i, f"{name}: {raw[i - 1].strip()[:90]}"))

        low = line.lower()
        for word in FORBIDDEN:
            if re.search(rf"\b{re.escape(word)}\b", low):
                problems.append((i, f'forbidden phrase "{word}"'))

    for i in range(len(text) - 1):
        line = text[i].rstrip()
        if not line.endswith(":") or line.endswith("::"):
            continue
        nxt = i + 1
        while nxt < len(text) and not text[nxt].strip():
            nxt += 1
        if nxt < len(text) and LIST_ITEM.match(text[nxt]):
            problems.append((i + 1, f"colon introduces a list: {line.strip()[:90]}"))

    return [(rel, ln, msg) for ln, msg in problems]


def main():
    allow = load_allowlist()
    failures = []
    checked = 0

    for path in sorted(DOCS.rglob("*.md")):
        rel = str(path.relative_to(ROOT))
        if rel in allow:
            continue
        checked += 1
        failures.extend(check(path, rel))

    stale = sorted(a for a in allow if not (ROOT / a).exists())
    for a in stale:
        print(f"allowlist names a file that no longer exists: {a}", file=sys.stderr)

    if failures:
        print(f"docs style: {len(failures)} problem(s) in {checked} checked file(s)\n")
        for rel, ln, msg in failures:
            print(f"  {rel}:{ln}: {msg}")
        print(
            "\nSee docs-redesign/06-voice-and-style.md. If this is a page from the "
            "pre-existing backlog (#911), it belongs in scripts/docs-style-allow.txt "
            "until it is cleaned."
        )
        return 1

    if stale:
        return 1

    print(f"docs style: clean ({checked} files checked, {len(allow)} on the backlog)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
