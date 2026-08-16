---
type: ADR Template
title: "ADR template (copy this when writing a real ADR)"
description: "Copy this file to write a new ADR; it fixes the frontmatter, the section shape, and the rule that unbuilt behavior is never described as built."
tags: [meta, template]
status: stable
adr: "0001"
adr_status: "Template"
generated: { by: human:jhgaylor, at: 2026-08-02T04:03:06-04:00 }
---

# 0001 — ADR template (copy this when writing a real ADR)

**Status:** Template — not a real decision. Copy this file as `decisions/NNNN-<short-title>.md` and fill it in.

## Frontmatter

Every ADR opens with an [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
frontmatter block. `okf validate decisions` runs in CI and fails on a missing
`type`, a malformed date, or a link to an ADR that is not on this branch.
Copy this block and fill in every line:

```yaml
---
type: ADR
title: "<title, without the NNNN prefix>"
description: "<one sentence a reader can act on without opening the file; name what is unbuilt>"
tags: [<area>, <area>]
status: stable            # OKF lifecycle: draft (Proposed) | stable (Accepted) | deprecated (Superseded)
adr: "NNNN"
adr_status: "Accepted"    # Proposed | Accepted | Partially accepted | Superseded by NNNN
date: YYYY-MM-DD          # the day the decision was made or proposed
generated: { by: human:<github-handle>, at: <ISO 8601 datetime of the last meaningful edit> }
verified: { by: human:<github-handle>, at: <ISO 8601 datetime> }   # only once checked against the code
stale_after: YYYY-MM-DD   # required while anything described is unbuilt; the date to re-check the status block
---
```

`verified` is the machine-readable form of "nothing described here is
unbuilt" (or of an explicit built / not-built accounting in the status block).
Set it when you have checked the ADR against the code, update `at` when you
check again, and never set it on a status block you have not checked. Anything
Proposed or Partially accepted carries `stale_after`; the PR that finishes the
build removes it along with the "not yet built" caveats. Regenerate the index
with `scripts/decisions-index.sh` after adding or renaming an ADR.

Real ADRs carry a status too: `Proposed` (decision not yet made), `Accepted`
(decided; may describe behavior that is not all built yet — if so, name what
is unbuilt), or `Superseded by NNNN`. Never describe unbuilt behavior as
existing: the 2026-07 audit (#200) found three mechanisms asserted as
implemented that did not exist, and every reader of those ADRs was misled
until code was checked (#271). The PR that builds a described mechanism
removes its "not yet built" caveat in the same change.

## Context

What's the situation forcing a choice? What constraints make this non-obvious? Link to relevant briefs, prior ADRs, or external docs.

## Decision

What we're doing. One paragraph. Be specific enough that a specialist reading this six months from now can act on it without asking.

## Consequences

What changes as a result? What are we giving up? What second-order effects should we expect?

## Alternatives considered

- **<option A>** — <one line on why not>.
- **<option B>** — <one line on why not>.
