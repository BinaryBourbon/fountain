## Context

G0 resolved: Fountain will be Option B — API + Hosted UI with self-serve onboarding. It is a multi-tenant rebuild of `jhgaylor/aod-ex` targeting external users who want preconfigured, sandboxed coding-agent instances. Read the product description in `OPERATING_MODEL.md`, the scope decision in `decisions/0003-direction-option-b-api-ui-onboarding.md`, and the scope comparison at `plan/phase-0-framing/scope-comparison.md` before writing.

This press release is the input to G1. It locks the narrative before engineering scope is set.

## Task

- Produce `plan/phase-1-press-release/press-release.md`: a 1–2 page fictional launch press release written as if Fountain Option B has just shipped.
- Use Amazon PRFAQ format: headline, sub-headline, dateline, opening paragraph, customer problem, solution narrative, key features (3–5), customer quote, call to action.
- Anchor the problem to the concrete pain: running Claude instances with worktrees locally and shuffling MCP configurations, skill setups, and env vars by hand is painful at team scale. Fountain removes that friction.
- Write for the human operator deciding whether this is the product they want to build — not for a general audience.

## Acceptance

- `plan/phase-1-press-release/press-release.md` exists in a PR against `main` on `BinaryBourbon/fountain`.
- The document reads like a real launch announcement, not a spec or feature list.
- A reader unfamiliar with aod-ex can understand the value proposition from the press release alone.
- PR description states: "Does this narrative match what you want to build? Approve to lock G1."

## Out of scope

- Do not write FAQs, architecture docs, or engineering plans.
- Do not modify `OPERATING_MODEL.md`, `ROADMAP.md`, or any `decisions/` file.
- Do not propose specific technical implementation choices.
- Do not pick a different scope — Option B is decided.
