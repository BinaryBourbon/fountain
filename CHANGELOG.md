# Changelog

All notable changes to Fountain are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Pre-1.0, a minor bump (`0.x` → `0.y`) may include breaking changes; when one
does, the release carries an **Upgrade notes** section. Patch releases are
always safe to take. Every release publishes the server image to
`ghcr.io/binarybourbon/fountain` as `vX.Y.Z` (immutable) and `vX.Y` (moving,
newest patch in the line). The full policy, including how migrations run on
upgrade, is in
[Versioning and upgrades](https://binarybourbon.github.io/fountain/self-hosting/#versioning-and-upgrades).

---

## [Unreleased]

### Upgrade notes

- Set `PUBLIC_URL` to your external URL, scheme included. It is now separate
  from `PHX_HOST` and is what generated links, OAuth callbacks, and sandbox
  callbacks are built from (#204). An `https://` `PUBLIC_URL` also switches on
  the HTTPS redirect, HSTS, and secure session cookies (#241) — if you
  terminate TLS in front of Fountain, your proxy must set `X-Forwarded-Proto`.
- Production now refuses to boot without a mail setting. Configure
  `RESEND_API_KEY`, `SMTP_HOST`, or explicitly opt out with
  `EMAIL_DELIVERY=none` (#223).
- Migrations continue to run automatically at boot; no manual steps.

### Added

- Optional error tracking via Sentry (or any Sentry-API-compatible endpoint):
  crashes from every process — not just web requests — are reported with
  release correlation, rate-limited, with PII off. Fully inert unless
  `SENTRY_DSN` is set (#211)
- A portable Kubernetes baseline under `deploy/k8s/` — plain manifests,
  `kubectl apply -k`, no operators assumed; bring a Postgres and an ingress
  (#191)
- Dialyzer now gates CI and `mix precommit` (#236). Triage of its 77 findings
  fixed real bugs: OTel spans were ended by passing the span where a
  timestamp belongs (silently corrupting recorded spans), Stripe API params
  used strings where the client's specs say atoms, six schema modules never
  defined the `t()` their specs referenced, and `upsert_oauth_user`'s spec
  omitted the registration-refusal atoms — making dialyzer condemn the live
  controller branch handling them. Three understood warnings are pinned in
  `.dialyzer_ignore.exs` with reasons
- Transient Sprites API failures no longer fail provisioning outright:
  idempotent steps retry with bounded exponential backoff, sprite creation
  adopts an already-created sprite after a lost response, and the Sprites
  HTTP timeout is explicit and tunable (`SPRITES_TIMEOUT_MS`) (#168)
- Admin support tooling: subscription status, trial end and a Stripe dashboard
  link per user, trial extension (Stripe-aware), a `comped` status for
  operator-granted free access, per-user 30-day usage, and a sandbox reap
  action (#169). Admin account deletions are now actually audit-recorded —
  the event type was missing from the audit allowlist and failed validation
  silently
- Bulk manifest apply — a whole manifest in one request, and the CLI's
  `fountain apply` uses it (#151)
- Agent-scoped vault allowlists: an agent can be restricted to a named set of
  vaults (#144)
- `networking_config` on Environment, typed and documented (#146)
- `metadata` field on Environment and Vault for external tooling (#145)
- `GET /api/auth/api-keys` — list active keys, metadata only (#143)
- GitHub-sourced agent skills require a ref/SHA pin (#149)
- Account deletion, self-serve and admin (#234)
- Billing that holds: real Stripe trial subscriptions with end dates (#244), a
  warning email three days before a trial ends (#251), usage events (#213),
  idempotent order-aware webhooks (#214), and billing gates on every
  provisioning path (#212)
- Sandbox lifecycle bounds: per-tenant concurrent-sandbox cap (#205), idle
  timeout and maximum age (#233), and a reaper for leaked sprites and rows
  stuck mid-provision (#232)
- Durable job queue (#217)
- Self-hosting support: compose file and guide (#225), configurable
  `SPRITES_BASE_URL` (#189), database TLS / billing / registration switches
  (#224), SMTP delivery (#223), split liveness and readiness probes (#230),
  and an explicit MIT licence (#226)
- LLM-generated conversation titles, agent avatars, unread indicators, and a
  live-updating sidebar
- Public documentation site (MkDocs); OTel instrumentation for the
  conversation lifecycle (#125); Prometheus/Loki/Alertmanager wiring for the
  hosted instance (#210)
- Context-level and property-based test suites, with coverage held above a CI
  floor

### Changed

- Agent, environment, and vault editors use structured form UI instead of raw
  JSON textareas (#122–#124)
- Sandboxes are named `fountain-<tenant>-<id>` (#70)
- The hosted instance runs two clustered replicas (#132), with a single
  elected leader for conversation rehydration (#133)
- CI actually gates: strict Credo, coverage floor, sobelow, secret scanning,
  CLI tests on release (#237), and a smoke test that boots the built image
  against its own health probes (#249)
- Deploys pin the exact built image on a dedicated `deploy` branch so manifest
  and image can never diverge (#250)

### Removed

- SSH repository clones (#228). Implemented and hardened but unreachable —
  validation has required `https://` since the schema existed, and production
  confirmed zero use. Private repos are covered by https + token secrets; the
  implementation stays in git history if demand appears

### Fixed

- Conversations no longer replay their last prompt on every deploy (#248)
- The SSE stream endpoint no longer 406s real clients (#229), and the CLI
  resumes a dropped stream instead of reporting success (#219)
- `force_ssl` is applied as a runtime plug (#243), with health probes exempt
  from the HTTPS redirect (#245)
- Paid checkouts are never orphaned (#212)
- Turn images are validated at ingest, not only on serve (#235)
- `agents.skills` migrated from `text[]` to `jsonb[]` (#65)
- `PasswordResetController` returns `422 Unprocessable Entity` (was `200 OK`)
  on validation failure

### Security

- HSTS, secure cookies, and a scoped `check_origin`, all derived from
  `PUBLIC_URL` (#241)
- OAuth identities require a provider-verified email before linking (#240)
- Tenant secrets are redacted from sprite output before it is persisted (#222)
- Real client IP resolution behind proxies, and rate-limited login forms
  (#216)
- Tenant scoping tightened across the conversation spawn graph (#215), turn
  images (#202), sprite callback tokens — now with key expiry (#206), audit
  events (#68), and per-conversation `FOUNTAIN_TOKEN`s scoped to their owner
  (#75)
- Provisioning hardening: `.env` values quoted inertly (#227)
- Audit coverage extended to the browser surface, auth events, and admin
  actions (#221); external audit findings addressed (#129, #130)

## [0.2.1] — 2026-05-10

### Fixed

- CLI defaults its base URL to `fountain.inevitable.fyi` (#62)
- Dashboard "Recent conversations" card links to `/conversations`

## [0.2.0] — 2026-05-10

### Added

- Public marketing landing page at `/`
- Cross-tenant security regression suite (#55)

### Changed

- CLI ported from Elixir/Burrito to Go; the Elixir CLI and its release
  pipeline are removed (#60, #47, #50)
- Unscoped context functions renamed `_unsafe_*` as an enforcement convention
  (#54)

### Fixed

- Postgres `$N` placeholders in recursive CTE queries (#58)
- `fountain apply` strips ownership fields before POST/PUT (#59)

### Security

- Agent, Environment, Secret, and Vault controllers scoped to the
  authenticated user (#49, #51, #52); `user_id` propagated through
  `start_conversation` and orphaned rows backfilled (#48)

## [0.1.0] — 2026-04-01

### Added

- Multi-tenant API and UI for managing Agents, Environments, Vaults, and Conversations
- GitHub OAuth login via Ueberauth
- Stripe billing integration with subscription enforcement
- Per-tenant envelope encryption for secrets (AES-256-GCM, per-tenant DEK)
- Sprites sandbox platform integration (spawn / poll / stream log events)
- LiveView UI: dashboard, agent editor, environment/vault editors, conversation viewer, admin panel
- REST API with API-key authentication and per-tenant rate limiting
- `fountain` CLI (`cli/`) with `auth`, `apply`, `get`, `describe`, `delete` commands
- `llms.txt` / `llms-full.txt` / `/skill` endpoints for LLM-native API discovery
- Audit log for state-changing actions (append-only, best-effort)
- Substitution engine for `${VAR}` / `$$` interpolation in agent configs

[Unreleased]: https://github.com/BinaryBourbon/fountain/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/BinaryBourbon/fountain/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BinaryBourbon/fountain/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/BinaryBourbon/fountain/releases/tag/v0.1.0
