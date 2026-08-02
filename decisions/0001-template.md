# 0001 — ADR template (copy this when writing a real ADR)

**Status:** Template — not a real decision. Copy this file as `decisions/NNNN-<short-title>.md` and fill it in.

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
