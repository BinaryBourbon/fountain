#!/usr/bin/env python3
"""Enforce the docs style sheet on docs/**/*.md.

Three rules, all from standards/voice-and-style.md:

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

TWO EXEMPTIONS THE FIRST DRAFT OF THIS SCRIPT GOT WRONG.

A table cell whose whole content is a dash is a placeholder meaning "none",
not a hinge in a sentence. `configuration.md` has 84 of them in its
default column. Forcing those to "n/a" would make the table worse, and the
rule exists to stop a dash carrying a clause, which a lone cell cannot do.

There is no directory exclusion any more. `docs/superpowers/` was one —
internal planning material that sat under `docs/` without a nav entry, so
MkDocs published it and /docs did not. #1008 retired the MkDocs site and made
"in docs/ but not in the nav" a test failure, and those four pages moved out
of docs/ (since deleted). Everything under `docs/` is now a published
page, so every page under `docs/` is checked.

A file whose first lines declare `<!-- GENERATED FILE` is skipped for the same
reason code fences are: it quotes the world rather than describing it. Editing
it would be undone by the next regeneration, and the fix belongs upstream in
whatever renders it. Cleaning the *source* of a generated page is real work and
belongs in its own change.

THE RATCHET. Files listed in scripts/docs-style-allow.txt are skipped. That
list is the pre-existing backlog (#911) and is only ever meant to shrink. A
file NOT on the list is checked, so anything new is covered by default and
the cleanup can land page by page without leaving CI red in between.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOW = ROOT / "scripts" / "docs-style-allow.txt"


def doc_roots():
    """Every directory whose markdown is published at /docs.

    The host's `docs/`, plus each extension's own (ADR 0043, #1510): an
    extension embeds its slice of the manual from `apps/<app>/docs/`, and those
    pages are served to the same readers by the same renderer, so they are held
    to the same style sheet.

    Discovered rather than listed. A page that moved out of `docs/` and into an
    extension would otherwise leave this gate silently, which is the failure
    the whole file is arranged against.
    """
    return [ROOT / "docs"] + sorted(ROOT.glob("apps/*/docs"))

FORBIDDEN = ["simply", "coming soon", "obviously"]
LIST_ITEM = re.compile(r"^\s*(?:[-*+]\s|\d+\.\s)")

# Declared by a generated page in its own header, so adding one needs no edit
# here. Checked against the first 2 KiB, which is past any front matter.
GENERATED_MARKER = "<!-- GENERATED FILE"

# A table cell holding nothing but a dash: `| — |`, `|—|`, and the row-start
# and row-end variants. This is a placeholder for "none", not prose.
PLACEHOLDER_CELL = re.compile(r"\|\s*[—–]\s*(?=\|)")


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
        # Drop placeholder cells before looking for prose dashes, so
        # `| VAR | — | prod | ... — ... |` still reports the prose one.
        prose = PLACEHOLDER_CELL.sub("|", line) if line.lstrip().startswith("|") else line
        for ch, name in (("—", "em dash"), ("–", "en dash")):
            if ch in prose:
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
    generated = []
    checked = 0

    pages = sorted(p for root in doc_roots() for p in root.rglob("*.md"))

    for path in pages:
        rel = str(path.relative_to(ROOT))
        if rel in allow:
            continue
        if GENERATED_MARKER in path.read_text()[:2048]:
            generated.append(rel)
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
            "\nSee standards/voice-and-style.md. If this is a page from the "
            "pre-existing backlog (#911), it belongs in scripts/docs-style-allow.txt "
            "until it is cleaned."
        )
        return 1

    if stale:
        return 1

    note = f", {len(generated)} generated" if generated else ""
    print(
        f"docs style: clean ({checked} files checked, "
        f"{len(allow)} on the backlog{note})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
