## Context

Fountain is a new multi-tenant API and UI for managing agents, repos, secrets, and conversations — targeting external users who want preconfigured, sandboxed coding-agent instances. `jhgaylor/aod-ex` (Fountain's reference implementation per `decisions/0002-aod-ex-as-reference.md`) does this today for a single operator locally. Your job is to frame the delta: what must change when we rebuild for multi-tenant, external-user use.

Success metric: 100 weekly active users by month 6. That user's needs — not the operator's — should anchor your framing.

## Task

- Read `jhgaylor/aod-ex` (README, CLAUDE.md, resource model) and extract the current primitive set: environments, vaults, agents, conversations, secrets, MCP/skill config.
- Identify at least two distinct product scope options for Fountain (e.g., minimal API-only vs. full API + UI with onboarding), each framed around the multi-tenant gap.
- Produce `plan/phase-0-framing/scope-comparison.md`: a structured side-by-side comparison of candidate scopes including — what aod-ex already covers, what must change for multi-tenancy (auth, isolation, billing surface, onboarding UX, debugging affordances), and tradeoffs for each option.
- Do not pick a direction — that is the G0 gate decision for the human operator.

## Acceptance

- `plan/phase-0-framing/scope-comparison.md` exists in a PR against `main` on `BinaryBourbon/fountain`.
- Each scope option names the aod-ex primitives it keeps, the ones it changes, and the multi-tenancy additions it requires.
- The document is readable without prior context — a new stakeholder can use it to make the G0 call.
- PR description summarises what the human operator needs to decide at G0.

## Out of scope

- Do not write code, architecture diagrams, or engineering plans.
- Do not propose a press-release narrative (that is G1 / growth-marketer territory).
- Do not modify `OPERATING_MODEL.md`, `ROADMAP.md`, or any `decisions/` file.
- Do not pick a winner or write a recommendation — leave the call to the human operator at G0.
