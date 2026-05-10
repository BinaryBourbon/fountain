# 0005 — Platform-shared `SPRITES_TOKEN` is the trust model for sandbox provisioning

**Status:** Accepted — 2026-05-09.

## Context

Fountain provisions sandboxes for tenants via Sprites. The Phase 2 engineering plan raised OQ-4a: how does Sprites authenticate? Three models were considered:

- **Platform-shared.** Fountain holds one `SPRITES_TOKEN`, uses it for every tenant's sandboxes. (aod-ex's model.)
- **Per-tenant delegation.** If Sprites supports issuing scoped sub-tokens, use one per tenant for stronger isolation while Fountain still pays.
- **BYO-token per tenant.** Each tenant signs up for Sprites separately and pastes their own token in onboarding. Fountain pays nothing for sandbox usage; isolation is account-level at Sprites.

The G2 conversation initially landed on BYO-token. The operator then surfaced a load-bearing constraint that flipped the call: **Sprites is an implementation detail Fountain should hide from end users**. That is the whole shape of the Option B direction (ADR 0003) — self-serve users should not know what Sprites is, should not have to hold an account there, should not paste tokens. Asking them to do so undoes the onboarding wizard.

This ADR pins the chosen model and, more importantly, captures the trust assumptions that make it safe — so future specialists touching the sandbox path don't quietly violate them.

## Decision

Fountain uses a **single platform-level `SPRITES_TOKEN`** for all tenants' sandbox provisioning. Tenants never see, hold, or rotate Sprites credentials. The token lives only as a Render env var (never persisted to the database, never surfaced in admin UI, never logged) and is loaded at runtime via `Application.fetch_env!(:fountain, :sprites_token)` inside `ConversationServer`.

Tenant isolation is enforced at two layers:

1. **Application layer (Fountain's responsibility).** Every context function scopes by `user_id`; no cross-tenant read is possible through the normal context API. See `plan/phase-2-build-plan/engineering-plan.md` §3 for the enumerated context-function changes.
2. **Sandbox layer (Sprites's responsibility, trusted).** Each conversation gets its own sandbox (`fountain-conv-<short-id>`). Sandboxes within the same Sprites account are isolated from each other — separate process/container/VM, no shared filesystem, no implicit network reachability. The Sprites API does not let one sandbox enumerate or read another's metadata or logs.

To bound noisy-neighbor risk on the shared Sprites account, **every tenant gets a Fountain-side concurrency cap** (`users.max_concurrent_sandboxes`, default 5, admin-adjustable per user). This is the load-bearing safety mechanism — without it, one tenant could exhaust Sprites' account-level rate limits and starve everyone else.

## Consequences

- Onboarding has no "connect Sprites" step. The wizard goes straight from email verification to first Environment, matching the Option B UX goal.
- Fountain pays for all sandbox usage on its Sprites bill. Tier pricing (set by growth/marketing pre-launch) must cover Sprites costs plus margin. Per-tenant usage is reconstructed from `usage_events` for cost attribution and metered billing.
- The `SPRITES_TOKEN` becomes a high-blast-radius secret. Mitigations that must be in place at launch:
  - Env var only — never in the database, never in logs, never displayed in admin UI.
  - Alerting on Sprites API anomalies (unusual sandbox count, unusual regions, sudden volume spikes) so a leaked token is detected by behavior, not by audit.
  - Documented rotation runbook (Render env-var update + restart; in-flight conversations finish on the old token if Sprites supports lazy invalidation, otherwise they crash and users retry).
- The per-tenant concurrency cap is no longer optional — it is the only thing standing between one tenant and all the others. Sprint 1 must implement it; admins must be able to adjust it; abuse response runbooks reference it.
- This ADR depends on Sprites' isolation guarantees. If those are weaker than assumed (e.g., sandboxes in the same account can reach each other on a shared internal network), this trust model breaks and the platform-shared approach becomes unsafe. **Action item before launch:** confirm Sprites' per-sandbox isolation properties in writing (docs or direct from the Sprites team).
- BYO-token can return as an *optional* power-user feature post-launch if a tenant explicitly wants their own Sprites account (e.g., for cost attribution or compliance reasons). It must not become the default.
- Per-tenant delegated sub-tokens (if Sprites adds this capability) would be a strict isolation upgrade with no UX cost. Worth revisiting at the next architectural review.

## Alternatives considered

- **BYO-token per tenant.** Initially chosen at G2; reversed once the operator clarified that Sprites must be hidden from users. Adds a hard onboarding step that breaks Option B's self-serve flow. Better isolation, but the operator priced isolation against onboarding friction and chose onboarding.
- **Per-tenant delegated sub-tokens via Sprites.** Rejected only because Sprites' current API support for delegation is unverified. If/when it lands, this is the upgrade path — same UX, stronger isolation, no change to the tenant-facing flow.
- **Run a separate Sprites account per tenant, managed by Fountain.** Rejected — the operational overhead (account creation, billing reconciliation across N accounts, support escalations) scales linearly with tenants. Defeats the purpose of a hosted product.
