# 0005 — Platform-shared SPRITES_TOKEN; per-tenant concurrency cap as noisy-neighbor mitigation

**Status:** Accepted — 2026-05-10.

## Context

Fountain must provision Sprites sandboxes for all tenants. Two models were considered: each tenant supplies their own Sprites token (BYO), or Fountain holds one platform-level token and manages provisioning for everyone.

The success metric (100 WAU by month 6) and the Option B onboarding goal (users arrive, sign up, start a conversation without touching infrastructure) make BYO-token friction-incompatible with launch.

## Decision

Fountain holds a single **platform-level `SPRITES_TOKEN`** that is used to provision all tenant sandboxes:

- `SPRITES_TOKEN` is an env-var-only secret on Render. It is never stored in the DB, never surfaced in the admin UI, and never visible to tenants.
- Each `ConversationServer` reads it from `Application.fetch_env!(:fountain, :sprites_token)` at provisioning time.
- Sprites sandbox naming: `fountain-<tenant-prefix>-<short-id>` (replacing `aod-conv-<short-id>` from aod-ex). `<tenant-prefix>` is the first 8 chars of the owning user's UUID; `<short-id>` is the first 8 chars of a fresh UUID.
- **Per-tenant concurrency cap** (`users.max_concurrent_sandboxes`, default `5`) is the primary noisy-neighbor mitigation. The cap is enforced in `Fountain.Quotas.check_sandbox_quota!/1` before `Sprites.create/2` is called.
- The cap is admin-adjustable per user (raise for trusted tenants, lower during abuse).
- Fountain pays the Sprites bill and prices its own tiers to recover the cost.

## Consequences

- A single token compromise exposes all tenants’ sandbox provisioning capacity. Mitigations: (1) env-var only, (2) Render environment-level access control, (3) anomaly alerting on Sprites API volume, (4) documented token rotation runbook.
- Fountain must engage Sprites to understand and proactively raise account-level rate limits as WAU grows.
- BYO-token is a viable post-launch power-user feature if the demand emerges; it doesn’t require an architecture change, just an optional per-user Sprites token that `ConversationServer` prefers over the platform token.
- The trust boundary for sandbox isolation is Sprites itself: each sandbox is an isolated Sprite. Verify before launch that the Sprites API does not let one sandbox enumerate or read another’s metadata or logs within the same account.

## Alternatives considered

- **BYO Sprites token per tenant** — Rejected at launch. Adds a required setup step that breaks self-serve onboarding; tenants would need to create and manage their own Sprites accounts before using Fountain.
- **Per-tenant Sprites sub-accounts** — Rejected. Not a feature the Sprites API currently supports.
