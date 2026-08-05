# 0010 — DB-backed instance settings, admin-editable at runtime

**Status:** Accepted — 2026-08-04. **Nothing described here is built yet.** The
PR that builds each mechanism removes its caveat here. Amends [0005](0005-platform-shared-sprites-token.md):
the "never stored in the DB, never surfaced in the admin UI" clause for
`SPRITES_TOKEN` is superseded by this decision.

## Context

Every piece of instance configuration is an env var read in
`config/runtime.exs` at boot — about 30 `:fountain` app-env keys. Changing any
of them means editing the deployment's environment and rolling the app.

That surface splits into two kinds:

- **Boot/infrastructure config** — `DATABASE_URL`, `SECRET_KEY_BASE`,
  `MASTER_SECRETS_KEY`, `PUBLIC_URL`/`PHX_HOST`, ports, mailer, Stripe/OAuth/
  Sentry library config. These are wired into the endpoint, Repo, or
  third-party libraries at boot, or are needed before the DB is reachable.
  A restart on change is inherent and fine.
- **Runtime operator policy** — the platform `SPRITES_TOKEN`, registration
  toggles, sandbox lifetime bounds, log budgets, prune windows. These are read
  from app env at call time (e.g. `Fountain.SpritesClient.get!/0`, the
  lifecycle sweeps), have no boot entanglement, and are exactly the knobs an
  operator wants to turn while watching the instance — reacting to signup
  abuse, tuning cost bounds, rotating a credential.

For the second kind, "edit env + redeploy" is the wrong loop. Rotating the
Sprites token — the single credential behind all tenant sandbox provisioning —
currently requires a deploy; ADR 0005's own consequences section calls for a
"documented token rotation runbook," and that runbook today is a rollout.

ADR 0005 decided the token is "env-var-only … never stored in the DB, never
surfaced in the admin UI." That was written when no admin surface existed.
There is now an admin UI behind `require_admin`, an audit log
(`Fountain.Audit`), and envelope encryption (`Fountain.Crypto`) with a master
key that already lives outside the DB — the ingredients that decision was
protecting against not having.

## Decision

Add a `Fountain.Settings` context backed by an `instance_settings` key-value
table, with an admin UI for editing:

- **Precedence: DB value if set, else env var.** The env vars keep working
  exactly as today and act as seed/fallback. A self-hosted instance configured
  purely by env never touches the table. An escape hatch
  (`Fountain.Release.clear_setting/1` release task) deletes a bad DB row so
  the env value applies again without a UI.
- **Secret values are encrypted at rest** under a single platform-level DEK —
  generated with `Fountain.Crypto.generate_dek/0`, wrapped under
  `MASTER_SECRETS_KEY` with `wrap_dek/1`, stored alongside the settings.
  `MASTER_SECRETS_KEY` itself stays env-only, so there is no chicken-and-egg:
  the DB never contains the key that decrypts it. Secret settings are
  write-only in the UI (masked, replace-or-clear, never displayed).
- **Reads are cached** (`:persistent_term`), busted on write via
  `Phoenix.PubSub` broadcast so all nodes in a cluster pick up changes without
  restart.
- **Every write goes through `Fountain.Audit.record/1`** with the acting
  admin, the key, and (for non-secrets) old/new values.

First slice, in priority order:

1. `sprites_token` (secret) — read path is already centralized in
   `SpritesClient.get!/0`; this makes token rotation a paste in the admin UI.
2. `registration_enabled`, `registration_allowed_email_domains`.
3. `sandbox_idle_timeout_minutes`, `sandbox_max_lifetime_hours`,
   `log_output_byte_budget`.

Candidates after that: `unverified_prune_after_days`,
`unverified_prune_exempt`, `support_email`, `stripe_price_monthly_cents`,
`sprites_base_url`, `sprites_timeout_ms`.

**Explicitly staying env-only:**

- Boot-critical and library-wired config (everything in the first bullet list
  above) — restart-on-change is inherent.
- `TRUSTED_PROXIES` — trust-boundary config; making the proxy list editable
  from a web UI turns an admin-session compromise into a rate-limit and
  IP-attribution bypass. It stays in deploy config where it gets review.
- `BILLING_ENABLED` — a deploy-level product invariant (ADR 0006, #336),
  coupled to the boot-time `STRIPE_WEBHOOK_SECRET` validation; flipping it
  live would skip that check.

## Consequences

- Sprites token rotation, registration lockdown, and cost-bound tuning stop
  requiring a deploy. Changes take effect cluster-wide within seconds and are
  attributed in the audit log.
- The token now exists encrypted in the DB and its backups. The blob is
  useless without `MASTER_SECRETS_KEY`, which never enters the DB — the same
  posture as tenant secrets today. Still never visible to tenants, and not
  readable back out of the admin UI either.
- The admin UI becomes a more valuable target: an admin-session compromise can
  now replace the platform token (point provisioning at an attacker's
  account) or open registration. Mitigations: writes audited, secrets
  write-only, and the settings page sits behind `require_admin` like the rest
  of the admin surface. Anything whose compromise is worse than that
  (`TRUSTED_PROXIES`) is excluded above.
- Two sources of truth per setting. The precedence rule is one sentence — DB
  wins, env is fallback — but the admin UI must show which source is live for
  each key, or debugging "why is this value in effect" gets worse, not
  better.
- ADR 0005's storage clause is superseded; 0005 carries an addendum pointing
  here. Its actual decision — one platform token, per-tenant concurrency cap —
  is unchanged.

## Alternatives considered

- **Keep everything env-only** — status quo; leaves credential rotation and
  abuse response gated on a deploy pipeline, and makes the registration
  toggles effectively operator-only when they should be admin-usable.
- **Sync from an external secret manager (Infisical operator already
  materializes prod secrets)** — hosted-only answer; does nothing for
  self-hosters, and env vars are read at boot so a sync still implies a
  restart. Doesn't provide an admin UI or audit trail in-product.
- **Config file + reload signal** — solves restart but not the UI, audit, or
  cluster-distribution problems; operators would be editing files on nodes.
- **A feature-flag service** — right shape for booleans, wrong shape for
  secrets, and a new dependency for what one table and one context can do.
