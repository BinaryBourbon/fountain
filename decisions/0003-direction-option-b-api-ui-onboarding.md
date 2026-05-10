# 0003 — Fountain targets Option B: API + Hosted UI with Self-Serve Onboarding

**Status:** Accepted — 2026-05-10.

## Context

The `phase-0-framing` slice produced a side-by-side scope comparison at `plan/phase-0-framing/scope-comparison.md`. Two options were framed:

- **Option A** — API-only multi-tenant core. Faster to ship; narrower TAM; targets developer integrators.
- **Option B** — API + Hosted UI + Self-Serve Onboarding. Broader TAM; higher engineering cost; opens to non-developer users.

The G0 gate required the human operator to choose a direction before engineering and design work begins. The success metric is 100 weekly active users by month 6.

## Decision

Fountain will pursue **Option B — API + Hosted UI with Self-Serve Onboarding**:

- All aod-ex primitives (environments, vaults, agents, conversations, secrets, sandbox, turns, log events) are carried forward and rebuilt with tenant scoping across three surfaces: REST API, Phoenix LiveView dashboard, CLI.
- Multi-tenancy additions in scope: per-user identity and API keys, resource isolation by tenant, per-tenant secret envelope encryption, sandbox quotas, usage events, billing surface, self-serve onboarding wizard, in-browser log viewer, scoped admin tooling.
- Org/team features (shared environments and agents within a team) are deferred post-launch unless scope review changes this.

## Consequences

- The growth-marketer drafts a press-release-first spec anchored to Option B before engineering scope is locked (G1).
- Designer and engineer work will cover all three surfaces.
- Engineering complexity is higher than Option A; auth UX, LiveView multi-tenant refactor, and onboarding flow are all in scope.
- If Option B proves too slow to reach early users, revisit Option A scope as a fallback at G2.

## Alternatives considered

- **Option A (API-only)** — Rejected at G0. Faster to ship but the 100 WAU target is harder without a visual surface and guided onboarding.
