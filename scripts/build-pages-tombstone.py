#!/usr/bin/env python3
"""Build the tombstone that replaces the retired GitHub Pages site.

#1008 retired the MkDocs build and made `/docs` the only publisher of the
manual. Deleting the workflow stopped new publishes but left the last snapshot
serving forever, which is worse than a 404: stale docs that nothing marks as
stale, drifting further from `/docs` with every docs PR.

This builds a site of redirects instead. Every URL the old site answered keeps
answering, and sends the reader to the same page at
https://managoat.com/docs. It is published once, by hand, from
`.github/workflows/pages-tombstone.yml`.

MkDocs served directory URLs, so `setup.md` was `/fountain/setup/` and
`catalog/index.md` was `/fountain/catalog/`. That is exactly the mapping
`Fountain.Docs.Compiler.slug_for/1` already makes, so the nav is the whole
input: one redirect per page it names.

An unknown path lands on `404.html`, which goes to the manual's home rather
than guessing. The pages that path could name are the ones that no longer
exist anywhere (`docs/superpowers/`, which MkDocs published without a nav
entry), so guessing would send a reader from one dead URL to another.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAV = ROOT / "docs" / "nav.yml"
DOCS = "https://managoat.com/docs"

# The two line shapes docs/nav.yml uses, same as the Elixir parser. A page
# entry at any indent; a section header carries no file and is skipped.
ENTRY = re.compile(r"^\s+- ([^:]+):\s*(\S+)\s*$")


def slugs():
    """Every page slug in the nav. `index.md` is "", `x/index.md` is "x"."""
    block = NAV.read_text().split("\nnav:\n", 1)
    if len(block) != 2:
        sys.exit("docs/nav.yml has no `nav:` block")

    out = []
    for line in block[1].splitlines():
        if not line.strip() or line.strip().startswith("#"):
            continue
        if not line.startswith(" "):
            break
        m = ENTRY.match(line)
        if not m:
            continue
        stem = m.group(2).rsplit(".", 1)[0]
        out.append("" if stem == "index" else re.sub(r"/index$", "", stem))
    return out


def page(target, note):
    """A redirect that works with JavaScript off, and keeps the fragment on.

    `meta refresh` is the one that survives a reader with no JS. It cannot
    carry `location.hash`, so the script goes first and does; browsers preserve
    a fragment across a meta refresh inconsistently, and an anchor is how these
    pages link to each other.
    """
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Moved to {DOCS}</title>
<link rel="canonical" href="{target}">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url={target}">
<script>location.replace({target!r} + location.hash);</script>
<style>
  body {{ font: 16px/1.6 system-ui, sans-serif; margin: 6rem auto; max-width: 34rem;
         padding: 0 1.5rem; color: #1f2328; background: #fff; }}
  a {{ color: #6d28d9; }}
  @media (prefers-color-scheme: dark) {{
    body {{ color: #e6e6e6; background: #16161a; }}
    a {{ color: #c4b5fd; }}
  }}
</style>
</head>
<body>
<h1>The documentation moved.</h1>
<p>{note}</p>
<p><a href="{target}">{target}</a></p>
</body>
</html>
"""


def main():
    out = ROOT / "_pages_tombstone"
    for stale in sorted(out.rglob("*"), reverse=True):
        stale.unlink() if stale.is_file() else stale.rmdir()
    out.mkdir(exist_ok=True)

    # This is a second parser for docs/nav.yml; Fountain.Docs.Compiler is the
    # one that decides what /docs actually serves. They were verified to
    # produce the identical 79 pages plus the home slug when this was written.
    # If they ever disagree, this site sends readers from a live URL to a 404,
    # which is the one outcome worse than the stale snapshot it replaces — so
    # check the page is really there rather than trusting the two agree.
    found = slugs()
    if not found:
        sys.exit("docs/nav.yml parsed to no pages at all")

    written = 0
    for slug in found:
        source = ROOT / "docs" / ((slug + "/index.md") if slug else "index.md")
        if not source.exists() and not (ROOT / "docs" / f"{slug}.md").exists():
            sys.exit(f"nav names {slug!r}, which is no page on disk")

        target = f"{DOCS}/{slug}" if slug else DOCS
        directory = out / slug if slug else out
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "index.html").write_text(
            page(target, "This page is now served by Fountain itself.")
        )
        written += 1

    (out / "404.html").write_text(
        page(DOCS, "That page is no longer here. The manual is served by Fountain.")
    )

    # GitHub Pages runs Jekyll unless told not to, and Jekyll skips a directory
    # whose name begins with an underscore. None of ours do today, but a future
    # nav entry could, and the failure would be one missing redirect in a site
    # nobody reads until they need it.
    (out / ".nojekyll").write_text("")

    print(f"tombstone: {written} redirects + 404.html in {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
