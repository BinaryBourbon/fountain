## Context

G1 locked. Fountain is a hosted multi-tenant rebuild of `jhgaylor/aod-ex` — API + Phoenix LiveView dashboard + CLI. The press release is at `plan/phase-1-press-release/press-release.md`. Option B scope is in `decisions/0003-direction-option-b-api-ui-onboarding.md` and `plan/phase-0-framing/scope-comparison.md`. Read aod-ex's README and CLAUDE.md (`jhgaylor/aod-ex`) to understand the starting point — primitives, resource model, data layer (SQLite + Ecto), runtime (Elixir/Phoenix), and deployment model (Sprites + Render).

This engineering plan must be detailed enough to unblock design and sprint planning at G2.

## Task

- Produce `plan/phase-2-build-plan/engineering-plan.md` covering:
  1. **Data model** — schema additions and changes for multi-tenancy: `users`, `api_keys`, `usage_events` tables; foreign key additions to existing primitives; per-tenant secret envelope encryption design (replace aod-ex's single `SECRETS_KEY`).
  2. **Auth architecture** — sign-up / email verification flow, API key issuance and revocation, session management for LiveView, middleware/plug design.
  3. **Tenant isolation** — how every query and SSE subscription is scoped to the authenticated tenant; what aod-ex contexts need changing.
  4. **Sandbox quotas** — per-tenant concurrency limits and Sprites token pooling approach.
  5. **Billing surface** — usage event emission points (Turn-started, Sandbox-provisioned); webhook stub design for payment provider integration.
  6. **LiveView refactor scope** — which existing LiveView modules from aod-ex need multi-tenant changes; what new LiveViews are required (onboarding wizard, log viewer, billing UI).
  7. **CLI distribution** — how to ship a pre-configured binary pointing at the hosted service; auth via API key rather than `ADMIN_TOKEN`.
  8. **Migration path** — how an existing aod-ex operator migrates Environments and Agents to Fountain via REST API.
  9. **Deployment** — what changes in `render.yaml` / Sprites deploy for multi-tenant (persistent disk sizing, `SECRETS_KEY` per tenant vs. KMS approach, `AOD_PUBLIC_URL` routing).
- For each section, note open questions that require a human decision before implementation.

## Acceptance

- `plan/phase-2-build-plan/engineering-plan.md` exists in a PR against `main` on `BinaryBourbon/fountain`.
- Each of the nine sections is covered.
- Open questions are clearly marked so the operator can resolve them at G2.
- PR description summarises the biggest architectural bets and risks.

## Out of scope

- Do not write code or migrations.
- Do not design org/team features (deferred per `decisions/0003`).
- Do not modify `OPERATING_MODEL.md`, `ROADMAP.md`, or `decisions/` files.
- Do not pick a direction on open questions — flag them for G2.
