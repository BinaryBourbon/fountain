#!/usr/bin/env python3
"""Enforce ASD-STE100 Simplified Technical English on docs/**/*.md.

The standard is docs-redesign/08-simplified-technical-english.md. Read that
first. This script checks the part of it a machine can check.

ASD-STE100 has two halves. Part 1 is a dictionary of about 900 approved words,
each with one meaning and one part of speech. Part 2 is 65 writing rules. The
dictionary is licensed and is not in this repository, so this script does not
try to be it. It checks six things instead.

  1. SENTENCE LENGTH. A procedural sentence takes 20 words or fewer. A
     descriptive sentence takes 25 words or fewer. A line that is an ordered
     list item counts as procedural.
  2. PARAGRAPH LENGTH. A paragraph of descriptive text takes 6 sentences or
     fewer.
  3. NOT-APPROVED WORDS. A curated list of the words this repository used most
     that the dictionary rejects, each with the approved word to use instead.
     The list is short on purpose. It holds the words that came up, not every
     word the dictionary rejects.
  4. CONTRACTIONS. Write "do not", not "don't".
  5. THE PASSIVE VOICE. Rule 3.2 makes the active voice mandatory in
     procedures. Rule 3.3 makes it the default in description.
  6. -ING FORMS. Rule 3.4 rejects the present participle and the gerund. A
     word that ends in "ing" is allowed only when the dictionary holds it
     (during, string, warning) or when it is a Technical Name (billing,
     logging). ING_ALLOWED holds both sets.

WHAT IS EXEMPT.

Code fences, indented code and inline code spans quote the world rather than
describe it, so they are removed before any rule runs. So are link targets,
image targets, HTML comments and YAML front matter. A heading and a table cell
are prose and get the word rules, but not the length rules, because neither is
a sentence.

THE PER-LINE ESCAPE. A line that ends with `<!-- ste-ok -->` is skipped. It is
for a line that quotes somebody else's words, or for the rare passive that
Rule 3.3 permits because the actor is unknown. The count of them is printed on
every run, the same way the backlog is, so a growing number is visible.

THE RATCHET. Files listed in scripts/docs-ste-allow.txt are skipped. That list
is the backlog. It only shrinks. A file that is NOT on the list is checked, so
a new page is covered from the day somebody writes it, and the rewrite lands
one page at a time without CI going red in between.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ALLOW = ROOT / "scripts" / "docs-ste-allow.txt"

# Not in the nav, not served, not published. Historical planning material, the
# same exemption scripts/docs-style.py makes.
EXCLUDED_DIRS = ("docs/superpowers/",)

GENERATED_MARKER = "<!-- GENERATED FILE"
ESCAPE = "<!-- ste-ok -->"

MAX_WORDS_PROCEDURAL = 20
MAX_WORDS_DESCRIPTIVE = 25
MAX_SENTENCES_PARAGRAPH = 6

LIST_ITEM = re.compile(r"^\s*(?:[-*+]\s|\d+\.\s)")
ORDERED_ITEM = re.compile(r"^\s*\d+\.\s")

# Word -> what to write instead. Every entry is a word ASD-STE100 does not
# approve, paired with an approved word that carries the same meaning.
NOT_APPROVED = {
    "abort": "stop",
    "accomplish": "do",
    "additional": "more",
    "adequate": "enough",
    "advise": "tell",
    "allow": "let",
    "allows": "lets",
    "alter": "change",
    "alternatively": "or",
    "approximately": "about",
    "assist": "help",
    "attempt": "try",
    "cease": "stop",
    "commence": "start",
    "comprise": "have",
    "concerning": "about",
    "consequently": "so",
    "currently": "now",
    "demonstrate": "show",
    "desire": "want",
    "determine": "find",
    "due to": "because of",
    "employ": "use",
    "entire": "complete",
    "equivalent": "the same",
    "establish": "make",
    "examine": "look at",
    "excessive": "too much",
    "execute": "run",
    "exhibit": "show",
    "facilitate": "help",
    "furthermore": "also",
    "however": "but",
    "identical": "the same",
    "illustrate": "show",
    "in addition": "also",
    "in order to": "to",
    "in the event": "if",
    "indicate": "show",
    "indicates": "shows",
    "initiate": "start",
    "inquire": "ask",
    "insufficient": "not enough",
    "locate": "find",
    "maintain": "keep",
    "majority": "most",
    "may": "can, or must",
    "modify": "change",
    "numerous": "many",
    "obtain": "get",
    "occur": "happen",
    "occurs": "happens",
    "optimum": "best",
    "perform": "do",
    "permit": "let",
    "portion": "part",
    "possess": "have",
    "prior to": "before",
    "proceed": "continue",
    "provide": "give",
    "provides": "gives",
    "purchase": "buy",
    "receive": "get",
    "reduce": "decrease",
    "regarding": "about",
    "remainder": "the rest",
    "require": "need",
    "requires": "needs",
    "retain": "keep",
    "reveal": "show",
    "subsequently": "then",
    "sufficient": "enough",
    "terminate": "stop",
    "thus": "so",
    "transmit": "send",
    "utilise": "use",
    "utilize": "use",
    "via": "through",
    "whilst": "while",
    "with regard to": "about",
}

CONTRACTION = re.compile(
    r"\b(?:do|does|did|is|are|was|were|has|have|had|would|could|should|will|ca|wo)n't\b"
    r"|\b(?:it|that|there|here|what|who|he|she|let)'s\b"
    r"|\b(?:you|we|they|I)'(?:re|ll|ve|m|d)\b",
    re.I,
)

# be-verb followed by a past participle, with at most one adverb between them.
IRREGULAR_PARTICIPLE = (
    "born|brought|built|bought|caught|chosen|cut|done|drawn|driven|eaten|fallen|"
    "felt|found|given|gone|grown|held|hidden|hit|kept|known|laid|led|left|lost|"
    "made|meant|met|paid|put|read|run|said|seen|sent|set|shown|shut|sold|spent|"
    "split|spread|taken|taught|thrown|told|torn|understood|withdrawn|worn|written"
)
PASSIVE = re.compile(
    r"\b(?:is|are|was|were|be|been|being|gets|get)\s+"
    r"(?:(?:\w+ly)\s+)?"
    r"(?:(?:\w+ed)|(?:" + IRREGULAR_PARTICIPLE + r"))\b",
    re.I,
)
# "used to", "supposed to" and a handful of adjectives that end in -ed read as
# passives to the regex above and are not verbs at all.
PASSIVE_FALSE = re.compile(
    r"\b(?:is|are|was|were|be|been|being)\s+"
    r"(?:able|advanced|dead|detailed|elected|limited|mixed|red|"
    r"tired|united|unlimited|used\s+to)\b",
    re.I,
)

# Words that end in "ing" and are still allowed. Two groups: words ASD-STE100
# approves in its own right, and Technical Names this product uses as nouns.
ING_ALLOWED = {
    # In the dictionary as themselves.
    "during", "string", "strings", "thing", "things", "something", "nothing",
    "anything", "everything", "warning", "warnings", "morning", "evening",
    "ring", "spring", "bring", "king", "wing", "swing", "sing", "ceiling",
    "ceilings", "meaning", "meanings", "opening", "openings", "setting",
    "settings", "building", "buildings", "drawing", "drawings", "engineering",
    "heading", "headings",
    # Technical Names. A gerund that names a part of this system or another.
    "billing", "logging", "onboarding", "streaming", "polling", "routing",
    "caching", "hashing", "encoding", "pricing", "landing", "listing",
    "listings", "tracing", "sizing", "scaling", "sampling", "throttling",
    "pending", "outstanding", "housekeeping", "bootstrapping", "templating",
    "sharding", "chunking", "batching", "paging", "queuing", "monitoring",
    "provisioning", "versioning", "namespacing", "staging", "clustering",
    "debugging", "testing", "troubleshooting", "tooling", "branding",
}
ING_WORD = re.compile(r"\b([A-Za-z]{4,}ing)\b")

# Abbreviations whose full stop does not end a sentence.
ABBREV = {"e.g", "i.e", "etc", "vs", "no", "fig", "sec", "min", "max", "approx"}


def load_allowlist():
    if not ALLOW.exists():
        return set()
    out = set()
    for line in ALLOW.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


def strip_noise(lines):
    """Blank out code and other quoted material, keeping line numbers."""
    out = []
    in_fence = False
    in_front_matter = False
    for i, line in enumerate(lines):
        if i == 0 and line.strip() == "---":
            in_front_matter = True
            out.append("")
            continue
        if in_front_matter:
            if line.strip() == "---":
                in_front_matter = False
            out.append("")
            continue
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append("")
            continue
        if in_fence:
            out.append("")
            continue
        if line.startswith("    ") and not LIST_ITEM.match(line):
            out.append("")
            continue
        text = re.sub(r"`[^`]*`", " ", line)
        text = re.sub(r"<!--.*?-->", " ", text)
        text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
        text = re.sub(r"<[^>]+>", " ", text)
        out.append(text)
    return out


def word_count(text):
    return len(re.findall(r"[A-Za-z0-9$@_./-]+", text))


def split_sentences(text):
    """Split on terminal punctuation, keeping abbreviations and versions whole."""
    parts = []
    start = 0
    for m in re.finditer(r"[.!?]+(?=\s|$)", text):
        head = text[start : m.end()]
        token = re.split(r"[\s(]", head.strip())[-1].rstrip(".!?").lower()
        if token in ABBREV:
            continue
        if re.fullmatch(r"[\d.]*\d", token):
            continue
        parts.append(head.strip())
        start = m.end()
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return [p for p in parts if p]


def is_prose(line):
    """A line that carries sentences, as opposed to structure."""
    stripped = line.strip()
    if not stripped:
        return False
    if stripped.startswith("#"):
        return False
    if stripped.startswith("|") or set(stripped) <= set("|-: "):
        return False
    if stripped.startswith(">"):
        return False
    if stripped.startswith("!!!") or stripped.startswith("???"):
        return False
    return True


def check_words(line_no, line, problems):
    low = line.lower()
    for word, better in NOT_APPROVED.items():
        if re.search(rf"\b{re.escape(word)}\b", low):
            problems.append((line_no, f'not approved: "{word}", write "{better}"'))
    m = CONTRACTION.search(line)
    if m:
        problems.append((line_no, f'contraction: "{m.group(0)}", write it in full'))
    for m in PASSIVE.finditer(line):
        if PASSIVE_FALSE.match(m.group(0)):
            continue
        problems.append((line_no, f'passive voice: "{m.group(0)}", name the actor'))
    for m in ING_WORD.finditer(line):
        if m.group(1).lower() in ING_ALLOWED:
            continue
        problems.append((line_no, f'-ing form: "{m.group(1)}", use a simple tense'))


def check(path, rel):
    raw = path.read_text().splitlines()
    text = strip_noise(raw)
    problems = []
    escaped = 0

    for i, line in enumerate(text):
        if ESCAPE in raw[i]:
            text[i] = ""
            escaped += 1

    for i, line in enumerate(text, 1):
        if not line.strip():
            continue
        check_words(i, line, problems)

    # Sentence and paragraph length, over prose paragraphs only.
    para = []
    for i, line in enumerate(text, 1):
        if is_prose(line):
            para.append((i, line))
            continue
        flush(para, problems)
        para = []
    flush(para, problems)

    return [(rel, ln, msg) for ln, msg in sorted(set(problems))], escaped


def flush(para, problems):
    if not para:
        return
    procedural = any(ORDERED_ITEM.match(line) for _, line in para)
    limit = MAX_WORDS_PROCEDURAL if procedural else MAX_WORDS_DESCRIPTIVE
    joined = " ".join(LIST_ITEM.sub("", line).strip() for _, line in para)
    sentences = split_sentences(joined)
    first = para[0][0]
    for s in sentences:
        n = word_count(s)
        if n > limit:
            problems.append((first, f"sentence of {n} words (limit {limit}): {s[:80]}"))
    if len(sentences) > MAX_SENTENCES_PARAGRAPH and not procedural:
        problems.append(
            (first, f"paragraph of {len(sentences)} sentences (limit "
                    f"{MAX_SENTENCES_PARAGRAPH})")
        )


def main():
    allow = load_allowlist()
    failures = []
    generated = []
    checked = 0
    escapes = 0

    for path in sorted(DOCS.rglob("*.md")):
        rel = str(path.relative_to(ROOT))
        if rel in allow or rel.startswith(EXCLUDED_DIRS):
            continue
        if GENERATED_MARKER in path.read_text()[:2048]:
            generated.append(rel)
            continue
        checked += 1
        found, escaped = check(path, rel)
        failures.extend(found)
        escapes += escaped

    stale = sorted(a for a in allow if not (ROOT / a).exists())
    for a in stale:
        print(f"allowlist names a file that no longer exists: {a}", file=sys.stderr)

    if failures:
        print(f"docs STE: {len(failures)} problem(s) in {checked} checked file(s)\n")
        for rel, ln, msg in failures:
            print(f"  {rel}:{ln}: {msg}")
        print(
            "\nSee docs-redesign/08-simplified-technical-english.md. If this is a "
            "page from the backlog, it belongs in scripts/docs-ste-allow.txt until "
            "it is rewritten."
        )
        return 1

    if stale:
        return 1

    note = f", {len(generated)} generated" if generated else ""
    esc = f", {escapes} escaped line(s)" if escapes else ""
    print(
        f"docs STE: clean ({checked} files checked, "
        f"{len(allow)} on the backlog{note}{esc})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
