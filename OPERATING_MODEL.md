# Operating Model

This is the bible the [`captain-picard`](https://github.com/jhgaylor/aod-specs/blob/main/agents/teams/captain-picard/captain-picard.yml) orchestrator reads at the start of every conversation. Keep it tight — anything here that drifts from reality will mislead every dispatch downstream.

Run `/bootstrap` in Claude Code to fill the `<TODO>` blocks below interactively. After that, edit by hand as the product evolves.

---

## Product

**Name:** Fountain

**Description:** A multi-tenant API and UI for managing agents, repos, secrets, and conversations. It's for people who want to create sandboxed coding agent instances with preconfigured sets of env vars, MCP servers, skills, repos, and packages. Users treat Fountain as a building block for their own workflows, but also use the UI to get started and to debug. It exists because running Claude instances with worktrees locally — and shuffling MCP configurations and skill setups by hand — is painful. `jhgaylor/aod-ex` already does this for a single tenant, but it targets a different user; Fountain takes that core and rebuilds around multi-tenant use.

**Success metric:** 100 weekly active users by month 6.

## Roles

The captain-picard fleet (from [`jhgaylor/aod-specs`](https://github.com/jhgaylor/aod-specs)) has eight specialists. This team uses all of them:

- `customer-researcher` — when validating a problem, framing, or user need before committing engineering effort.
- `growth-marketer` — when crafting launch narratives, press-release-first specs, or growth experiments.
- `designer` — when interaction or visual design needs to land before engineering.
- `general-purpose-engineer` — for typical feature, bug, and refactor work.
- `pr-reviewer` — to review specialist PRs before merge when the orchestrator wants a second opinion.
- `release-validator` — to gate a deploy on functional + smoke-test passes.
- `reliability-engineer` — to investigate incidents, set up observability, or harden hot paths.
- `product-analyst` — to query PostHog/Honeycomb for evidence before/after a change.

## Gates

The orchestrator stops at every gate listed below and waits for the human operator to make the call. Don't add gates the team won't actually defend — every extra gate is friction.

- **G0** — Pick a product direction. Stops after `phase-0-framing`. Human picks the option.
- **G1** — Press-release narrative locked. Stops after the growth-marketer drafts the launch narrative. Human approves direction.
- **G2** — Architecture and engineering plan locked. Stops after engineer + designer produce a build plan. Human approves scope.
- **G3** — Ready to ship. Stops before public launch. Human gives go/no-go.

## Brief format

The orchestrator dispatches specialists with a written brief at `plan/<slice>/<role>-brief.md`. Keep briefs under 30 lines.

```
## Context
<2–4 lines — what slice, what's been decided, what specialist needs to know>

## Task
<bullets — concrete deliverables>

## Acceptance
<bullets — how the orchestrator will verify the PR is done>

## Out of scope
<bullets — things the specialist must NOT do in this PR>
```

## Working agreements

- **Every change to this repo lands as a PR.** No specialist pushes to `main`. The orchestrator merges after acceptance.
- **The orchestrator pushes after every state change.** Briefs, ROADMAP edits, and ADRs that aren't pushed are invisible to the next conversation.
- **Two slices in flight max.** If `ROADMAP.md`'s "Now" has two entries, finish one before dispatching another.
- **Decisions become ADRs.** When something gets contentious or needs to constrain future work, write `decisions/NNNN-<title>.md`. Use [`decisions/0001-template.md`](decisions/0001-template.md).
