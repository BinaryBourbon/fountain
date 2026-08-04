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

Nothing yet.

## [0.4.0] — 2026-08-04

### Upgrade notes

- **`BILLING_ENABLED` now defaults to `false`** — the subscription gate is
  opt-in. An instance that relies on the gate must set `BILLING_ENABLED=true`
  explicitly before upgrading, or every account gets ungated access (the
  repo's hosted manifest under `k8s/` already sets it). See the #336 entry
  under Changed

- **A billing-enabled production instance now refuses to boot without
  `STRIPE_WEBHOOK_SECRET`** (#390). The webhook endpoint previously fell back
  to an empty signing secret, which is a signature anyone can forge, so the
  fallback is gone: set the secret, or leave `BILLING_ENABLED=false`. An
  instance with billing off is unaffected

- One migration adds a **unique** index on `users.stripe_customer_id`
  (#411), replacing the plain index. If a pre-upgrade instance has two
  accounts pointing at the same Stripe customer, the migration fails — resolve
  the duplicate before upgrading. Duplicates were themselves the bug: the
  webhook lookup raised and 500ed every delivery for that customer

- The compose quick start now pins an explicit image tag rather than tracking
  `latest` (#410). `.env.compose.example` ships the pin uncommented; an
  existing `.env` keeps whatever it already had, so set `FOUNTAIN_IMAGE_TAG`
  deliberately when you upgrade

### Added

- Point-in-time recovery for the hosted database (#209): continuous WAL
  archiving plus nightly base backups via the CNPG barman-cloud plugin into
  the existing Garage bucket, retention 14 days, RPO ~5 minutes with the
  nightly `pg_dump` kept as the operator-independent fallback. The dump job
  now sends a Sentry Crons check-in, so a backup that quietly stops running
  pages instead of rotting

- Accounts that register and never verify their email are deleted after 30
  days (#258) — they cannot log in, and 158 of them were briefly mistaken for
  a legacy trial cohort. Same teardown as self-serve deletion, Stripe
  cancellation included; `UNVERIFIED_PRUNE_AFTER_DAYS=0` disables,
  `UNVERIFIED_PRUNE_EXEMPT` protects deliberate unverified accounts

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

- An account security page at `/account/security` (#448): a logged-in user can
  finally change their password (previously only the logged-out
  forgot-password flow existed) and change their email address at all. Both
  are current-password gated; a password change ends every other session and
  keeps the current one, and an email change is confirmed by clicking a link
  sent to the new address — which also marks it verified — while the **old**
  address gets a notice, the tripwire for a takeover in progress. OAuth-only
  accounts see an explanation and a pointer at the reset flow instead of forms
- A working resend-verification path (#445): `GET`/`POST
  /auth/resend-verification` and `POST /api/auth/resend-verification`, rate
  limited and with the same fixed-response anti-enumeration contract as the
  password-reset request. The check-your-email page had linked to this route
  for some time and the link was dead. The verification email itself moved to
  a durable background job — it used to be an in-request task the finishing
  response could kill, and a dropped email was unrecoverable with no resend
  path
- A welcome email on the transition to a verified account (#449), sent once
  per user forever, so pre-existing verified accounts are never welcomed late
- Notification emails for the two account-state transitions that used to
  happen silently (#450): suspension and unsuspension (re-checked at send
  time, so a suspension lifted before the queue drained is not announced) and
  deletion, whose copy is honest about what survives — Stripe keeps invoices,
  backups age out on their own schedule. The billing page's danger zone now
  points at the export section before the destructive click, and the optional
  `SUPPORT_EMAIL` puts a real reply-to address in the copy when set
- Account suspension — an abuse lever between comping and deleting (#287):
  sessions are invalidated, active sandboxes are best-effort reaped,
  provisioning is refused at the door, and billing is deliberately untouched
  so webhooks keep syncing. Refusals are neutral and password-checked first,
  so login, OAuth and API keys never become an account-state oracle
- Self-serve data export (#288): a tenant-scoped export built by a background
  job, downloadable from the account page through an owner-scoped expiring
  link. Secret values are deliberately excluded — names only
- An admin per-user detail view at `/admin/users/:id` (#446) — billing state,
  resource counts, conversations, API key metadata (never key material), the
  user's own audit trail and every admin action taken against them — plus a
  metadata-only admin conversation view at `/admin/conversations/:id`, where
  prompts, outputs and log content deliberately never render. Both
  cross-tenant reads are themselves audited. Before this, an admin could
  suspend or delete a user but not look at one, and conversation links 404ed
  for every conversation the admin did not personally own
- Admin user table search, filtering, sorting and pagination, with the state
  in URL params so a refresh or an admin action preserves position (#285)
- An admin billing overview (#286): status counts, trials ending in the next
  seven days, conversions this month, MRR from active subscriptions ×
  `STRIPE_PRICE_MONTHLY_CENTS` (nil when unconfigured — no fabricated
  numbers), and the recent webhook events
- An admin lifecycle funnel (#282): registered → verified → onboarded →
  activated → subscribed with per-stage conversion and median timing, a
  stalled-user breakdown answering how far the verified-but-never-ran accounts
  actually got, and the same stages exported as Prometheus gauges
- Post-trial and payment-failure lifecycle emails (#283): `trial_expired`,
  `payment_failed` and `subscription_canceled`, enqueued from webhook status
  transitions, where an enqueue or delivery failure can never error the
  webhook
- First-class dunning: `invoice.payment_failed`,
  `invoice.payment_action_required` and `invoice.paid` are handled instead of
  everything being inferred from subscription updates (#447). The SCA email is
  new and leads with the fix; a new payment-recovered email fires on the
  `past_due` → `active` transition; and `invoice.paid` writes status in
  exactly one case — dunning recovery — so the $0 invoice Stripe pays at trial
  creation and at every renewal can never touch the account
- Self-serve subscription management (#284): `cancel_at_period_end` and
  `current_period_end` sync from webhooks and are cleared on resubscription,
  an "access until <date>" notice while a cancellation is pending, a direct
  billing-history portal link, and a guard that routes an existing customer
  with any live subscription to the Billing Portal rather than handing them a
  second, duplicate subscription
- `mix fountain.verify_lifecycle` (#289): a repeatable end-to-end billing
  check driven by Stripe Test Clocks — trial → T-3d email → expiry → paid
  subscribe → cancel-at-period-end → period end → re-subscribe → dunning →
  recovery — asserting Fountain-side state at every step. Test-mode keys only,
  with cleanup that runs even on failure. Documented as the release check for
  any billing-touching change
- `Fountain.Release.promote_admin/1` (#275): first-admin bootstrap without raw
  SQL, symmetrical with `verify_email/1`, audit-recorded and idempotent. Both
  deploy guides drop their SQL step
- A per-conversation durable log budget (#331): output stops being persisted
  at `LOG_OUTPUT_BUDGET_MB` (default 50 MB, `0` disables), with one truncation
  marker written at the crossing. Retention bounds age, not rate, and
  `log_events` shares the volume the database depends on, so a sandbox
  printing garbage was an availability risk. The counter is cumulative across
  wakes
- An absolute provision deadline (#329): a server stuck inside provisioning
  was invisible to every reclamation mechanism — the reaper skips rows whose
  server is alive, and the server's own timers queue behind the stuck
  callback — so the sandbox billed until the next deploy. An external watchdog
  now kills it at 30 minutes and applies the normal provision-failure
  transitions
- Substantially more operational visibility: conversation and sandbox gauges
  by status plus Oban queue depth and job outcome metrics with alerts (#321),
  provisioning and turn metrics rewired onto events that actually fire (#310),
  alerts on the cost signals that previously fired into nothing — leaked
  untracked sprites, platform-wide sandbox and conversation ceilings,
  provision deadlines (#405) — CNPG PITR backup alerting (#338), and
  rehydrator sweep telemetry (#408)
- A self-host observability pack (#277): a generic `PrometheusRule` with every
  alert commented with its meaning and action, and a 12-panel starter Grafana
  dashboard built only from metrics the app actually exports
- A backup and restore story for both deploy paths (#276): a profile-gated
  nightly `pg_dump` service for compose, a generic backup CronJob for
  `deploy/k8s` targeting any S3-compatible store, and the restore drill in
  `docs/operations.md` with the `MASTER_SECRETS_KEY` pairing rule stated
  loudly — a database restored without its matching master key cannot decrypt
  any secret
- Public documentation for the parts that had none: a system architecture page
  with failure domains and the life of a conversation (#273), an operations
  and troubleshooting guide (#278), one guide per third-party integration —
  Sprites, GitHub OAuth, Stripe, Sentry, mail — with the required/optional
  matrix up front (#274), the Sprites dependency contract as consumed (#279),
  and a complete runtime configuration reference where every variable
  `config/runtime.exs` reads is documented, enforced by a test in both
  directions (#292)
- `fountain keys list --json`, matching every other list command, and
  first-time documentation of the `op://`, `bws://` and `infisical://` secret
  resolvers (#410)

### Changed

- Self-host first-run papercuts (#336): the GitHub sign-in button only renders
  when `GITHUB_OAUTH_CLIENT_ID` is configured (clicking it unconfigured
  dead-ended on a GitHub error page); the compose `app` service now has a
  healthcheck against `/health`; `TRUSTED_PROXIES` is documented in the
  `deploy/k8s` baseline; and **`BILLING_ENABLED` now defaults to `false`** —
  the subscription gate is opt-in (breaking; see Upgrade notes above)

- With billing disabled, an instance stops performing billing (#335): signups
  no longer enqueue a Stripe customer sync that 401s through all five attempts
  — dead jobs and error noise a self-hoster has no way to know are benign —
  and the billing page says plainly that billing is disabled instead of
  showing a trial countdown and an Upgrade button whose only possible outcome
  was "Unable to reach Stripe"
- Trace export is off unless an export target is configured (#317). It
  defaulted to OTLP aimed at Honeycomb whenever the app ran in production, so
  the portable baseline — which sets no OTEL variables — shipped continuous
  rejected span batches to a third-party vendor. Setting
  `OTEL_EXPORTER_OTLP_ENDPOINT`, `HONEYCOMB_ENDPOINT` or `HONEYCOMB_API_KEY`
  switches it back on
- Every route to a sprite is now gated on billing and suspension, not just
  fresh provisioning (#313). Reattaching to a live sandbox provisioned
  nothing, so it never met a gate; and a running conversation outlived the
  subscription state it started under, where every turn reset the idle clock —
  a trial that expired at minute one could buy up to 24 hours of continued
  service. The gate now also runs per turn, whichever door the prompt came in
  by
- The published OpenAPI spec describes this product (#423): it still called
  itself "Agent on Demand", pointed at the `aod` CLI and told integrators to
  authenticate with the `ADMIN_TOKEN` mechanism deleted two phases ago. It now
  names Fountain, the `fountain` CLI and per-user API keys, and the error
  table documents the `402` and `410` responses the API has been returning all
  along. The Conversation schema also drops an unreachable `completed` status
  and gains the `source` and `parent_conversation_id` fields it has been
  emitting, both now pinned by a drift test (#415)
- The production image is built on the same Elixir and OTP the test suite runs
  against (#425). The Dockerfile had drifted to a higher Elixir and a *lower*
  OTP than `.tool-versions` and CI; a test now fails if the three pins ever
  disagree again
- `k8s/` became a kustomize overlay of the portable `deploy/k8s` baseline
  (#264), so probes, security context, resources and rollout strategy exist
  once; the hosted overlay keeps only what is genuinely personal
- Deploys became less able to surprise: image builds trigger on a *successful*
  CI run rather than independently on push (#333), the manifest publish is
  gated by a `kustomize build` + `kubeconform -strict` + `promtool` validation
  job over both manifest trees (#414), the image-pin substitution is verified
  rather than assumed, and CI cancel-in-progress is now PR-only so a rapid
  merge cannot cancel another commit's build out from under it
- Rollouts drain properly (#408): a 120-second termination grace period and a
  preStop delay in the shared deployment base, plus a PodDisruptionBudget
  wired into the hosted manifests (shipped commented out in the portable base,
  where the 1-replica default would block drains)
- Container images are built natively per architecture instead of emulating
  arm64 under QEMU, with a registry layer cache (#361) — the same images,
  roughly 20 minutes sooner
- Manifests are published as an OCI artifact, and the `deploy` git branch that
  previously carried them is retired (#301, #303); rollback is now
  `flux tag artifact ... --tag latest` against an older `sha-` tag, documented
  in the workflow header
- `mix precommit` matches CI more closely: Credo no longer runs with
  `--mute-exit-status` (#333), sobelow was moved to where it actually scans a
  Phoenix app — at the umbrella root it detected nothing and exited 0, so the
  gate had scanned nothing since it was added — and now runs locally too
  (#311), and its threshold was lowered to the confidence level this codebase's
  entire XSS surface is reported at, with each of the 11 findings individually
  reviewed and justified in place (#414)

### Fixed

- A conversation's very first prompt could vanish (#367). It was cast through
  the distributed registry immediately after the server started, and a
  registration that has not yet propagated makes the cast a silent no-op: the
  API returned 201, provisioning succeeded, and zero turns ever ran. The cast
  now targets the pid directly
- Prompt, interrupt and terminate no longer 500 against a conversation that is
  still provisioning (#412). A blocked server means the call *exits* rather
  than returning an error tuple, and none of the seven call sites caught it;
  worst case was `DELETE`, where the 500 masked a delete that silently never
  ran. Callers now get a `503` with `Retry-After`, and the delete goes through
- A sprite WebSocket that dropped mid-turn left the turn "running" forever
  (#413): every further prompt answered "busy", idle reclaim was suppressed,
  the reaper skipped the sandbox, and the sprite billed until its 24-hour
  maximum lifetime. A dropped socket now fails the turn and returns the
  conversation to idle, the same shape as a non-zero exit
- The SSE stream now tells a client when the server behind it dies (#415)
  instead of sending heartbeats forever on a topic nothing will publish to
  again; a client disconnecting mid-replay no longer produces a crash report
  and a Sentry event per interrupted `curl`; and a spawn that never starts
  resets the conversation from `running` back to `idle`
- The provision watchdog now fails the database rows *before* killing the
  stuck server (#394). Killing first let the supervisor restart it into
  provisioning while the row still said pending — usually winning that race,
  provisioning a second billable sprite, and leaving a live server streaming
  into a sandbox whose row said terminal
- Concurrent requests can no longer exceed the per-tenant sandbox cap (#330):
  the quota check and the row insert now happen in one transaction under a
  per-user advisory lock. Separately, when two wakes of the same conversation
  raced, the loser stranded a pending row holding a quota slot until the
  reaper's next pass an hour later — a user at their cap could lock themselves
  out by double-clicking. The loser now cleans up and forwards its prompt to
  the winner
- Stripe webhooks whose apply failed are no longer lost (#312). The claim was
  written before the apply and outside any transaction, so the 500 that asks
  Stripe to redeliver was answered by a redelivery that deduped against the
  claim and did nothing. Claim and apply now share a transaction
- Webhook sync is keyed by the subscription of record, not the customer
  (#309). Upgrading mid-trial creates a second Stripe subscription, and events
  from either one wrote the same account — so Stripe cancelling the abandoned
  trial subscription locked out a customer who was paying on the other one.
  Checkout completion now cancels the other live subscriptions, and events for
  anything but the subscription of record never touch the account
- Webhook sync guards are evaluated under a row lock (#393), closing a window
  where a `customer.subscription.deleted` could read a user mid-upgrade,
  before the checkout transaction committed, and land its update afterwards —
  marking a just-paid customer canceled. The Stripe cancellation calls also
  moved out of that transaction, so no database lock is ever held across
  third-party HTTP
- An operator's trial extension outranks in-flight webhooks (#334): the
  extension now advances the sync watermark, so a straggler event from an old
  subscription can no longer silently revert the decision and re-gate the user
- Trial subscriptions are actually created at signup (#351). Two halves of the
  design cancelled each other — registration stamps a local trial end on every
  account, and the worker only opened a Stripe subscription when that field
  was nil — so no signup ever got one: no trial-ending warning, no cancellation
  at trial end, and nothing for the trial-expired email to hang off. The
  subscription now anchors to the locally-stamped date rather than restarting
  the clock
- Trial creation is idempotent (#400). Stripe statuses the changeset rejects
  made the write fail, the retry guard checked a field the failed write never
  set, and each of up to five retries created another subscription — all of
  which converted when the user later added a card. Statuses now go through
  the same coercion the webhook uses, and creation carries a stable
  per-user idempotency key
- A comped account is never offered Checkout (#399). Comping cancels every
  live subscription, so the billing page read a comped account as a fresh
  customer, showed Upgrade, opened Checkout and took the money — after which
  webhook adoption dropped the subscription id on the floor, making a paying
  customer invisible and locking them out when the comp was revoked
- The two usage numbers on the billing page no longer diverge for exactly the
  accounts whose provisioning is failing (#411): a sandbox that dies before
  reaching ready now emits its own usage event, counted by both summaries
- `docker compose up -d postgres` works on a fresh clone (#392). Compose
  interpolates the whole file regardless of which service you target, so the
  required-variable syntax on the app service aborted the documented
  database-only path — the very first command in `SETUP.md` — with an error
  about a service the contributor never asked to start
- Compose-style empty strings are treated as unset (#426). Passing optional
  variables as `${VAR:-}` makes them present-but-empty, and an empty string is
  truthy in Elixir, so every unset-guard written for these variables failed to
  fire: `RESEND_API_KEY=""` selected the Resend adapter and POSTed every
  verification and reset email — recipient address and live signed URL — to
  Resend to be 401'd, making the stock compose configuration's mail path
  unreachable; `SMTP_USERNAME=""` forced authentication with an empty
  username; and `SPRITES_TOKEN=""` defeated its own missing-token guard and
  turned a helpful message into an opaque 401
- `.env.compose.example` no longer advertises variables compose silently
  ignores (#410) — a new drift test immediately caught five, including
  `SPRITES_BASE_URL` and `REGISTRATION_ALLOWED_EMAIL_DOMAINS`
- LiveView pages reconcile state they used to load once at mount (#401): the
  conversation log viewer subscribed to a topic nothing publishes on, so live
  log events never arrived; the conversation header froze at its mount-time
  status instead of tracking the run; six delete handlers crashed on a row
  deleted in another tab instead of flashing; mid-session refusals show real
  messages instead of a raw atom; and `idle` — the resting state of every
  healthy conversation — gets the healthy badge colour instead of the
  unknown-value grey
- The API prompts endpoint maps every refusal to a 4xx (#332). Three known
  error shapes 500ed — the fourth time an unhandled shape hit this
  hand-maintained clause — and unmapped future ones now become a logged 422
  rather than a blank 500
- CLI: `keys create` decoded an envelope the server does not send, losing the
  plaintext key it had just minted; `conv prompt`/`stream` replayed full
  history and exited on the first *prior* turn's completion; and a failed turn
  exited 0 (#398). Provisioning and setup output is no longer silently
  dropped, so a failing `apt install` or `git clone` is visible, and server
  errors render as messages rather than raw Go map dumps (#410)
- Telemetry no longer dies for the lifetime of the pod after a single blip
  (#365, #395). The poller permanently drops a measurement whose tick fails,
  and the first collection fires while the database pool is still starting —
  verified on both production pods, where the funnel gauges were never
  recorded at all. The guards now cover raises, exits and throws, and the next
  tick retries
- The leaked-sprite metric was a level reported as a counter (#405), so a
  steady 102 untracked sprites read as 2,448 after a day and climbed forever
- Rate-limit buckets are swept every 10 minutes (#326). The table grew one row
  per distinct bucket and IP since boot — unbounded, and invisible until an
  instance stayed up long enough or someone walked an IPv6 range
- Unbounded growth elsewhere (#408): `log_events` gets the `inserted_at` index
  its nightly prune needs, expired export payloads are purged every run rather
  than only when someone requests another export, and expired API keys are
  pruned even when nothing revoked them
- Conversation server lifecycle races (#408): callback-key revocation now acts
  only on the key that server itself minted, so a rotation cannot revoke a
  live duplicate's credential under registry lag, and the supervisor has its
  own restart budget instead of sharing the default 3-in-5-seconds across
  every conversation on the node
- An admin event type missing from the audit allowlist no longer disappears
  silently (#451). It has happened twice; rejections now log at error level
  and emit a telemetry counter, and a static test scans for admin event
  literals that are missing from the list, so the mistake surfaces during
  development instead of as a hole in the privilege trail
- Client IP resolution behind the tunnel (#300): the endpoint listens on
  `[::]`, so IPv4 peers arrive as IPv4-mapped IPv6 addresses that never match
  a v4 CIDR — the trusted-proxy gate failed on every request and every
  rate-limit bucket and audit row keyed on the node gateway
- Release tasks run in production (#256): they used to boot the whole
  application, which beside a running server dies on `eaddrinuse` and would
  otherwise start Oban and the distributed registry on a throwaway node
  competing with the real cluster. The OpenAPI export job now migrates before
  booting (#255), and the release job downloads only the artifacts it ships
  (#257)

### Security

- The Stripe webhook endpoint fails closed when no signing secret is
  configured (#390). It resolved the secret from a key nothing sets and fell
  back to an empty string, so on every instance that never configured billing
  the signature check was an HMAC keyed on `""` — which anyone can compute,
  giving unauthenticated write access to subscription state through forged
  events. Requests are now rejected outright when the secret is missing (see
  Upgrade notes)
- The tenant data-encryption key is no longer held in LiveView assigns
  (#391). The environment and vault secret forms unwrapped the key at mount
  and kept it in process state with the in-flight plaintext secret beside it,
  reassigned on every keystroke — and LiveView crash reports dump channel
  state to the logger and to Sentry, so any unhandled exception leaked the key
  that decrypts the tenant's entire secret set. The key is now loaded inside
  the handler and the form is uncontrolled, so neither ever enters assigns
- Conversation server state is redacted from crash reports (#315). It holds
  plaintext sprite environment values, the raw tenant key, decrypted
  bring-your-own inference credentials, the sprite callback key and the
  platform Sprites token; a probe crash was verified to print every one of
  them before the fix
- Request bodies are scrubbed by shape, not by name, before reaching Sentry
  (#402). The SDK default is an exact-name denylist, so the secret-write
  endpoints' `value` field and a manifest apply's whole `spec.secrets` map
  arrived as plaintext whenever an exception fired mid-request. Every string
  value now becomes a length tag, which covers the next secret-bearing
  endpoint by default
- Password-reset tokens are single-use (#325). A used token stayed live for
  the rest of its hour and could re-reset the password from a shared inbox,
  forwarded mail or a proxy log. Legacy tokens issued before the upgrade fail
  closed and die out within one hour of deploy
- Agent output is no longer an XSS vector, and browser routes carry a Content
  Security Policy (#323). Worse than filed: the markdown renderer escapes
  *inline* raw HTML but passed *block-level* raw HTML through verbatim, so
  agent output containing an `<img onerror=...>` as its own paragraph was live
  XSS rather than a `javascript:` link behind a click. Rendering now goes
  through the AST with verbatim nodes escaped and link schemes filtered after
  entity and whitespace normalization
- An agent can only attach an environment owned by the same tenant (#308).
  The error deliberately mirrors a nonexistent id, so a foreign environment
  cannot be confirmed by probing, and the conversation server loads the
  environment scoped by owner as a second layer — a legacy cross-tenant row
  provisions without it rather than materialising another tenant's secrets and
  checkpoint into the attacker's sprite
- Password login against an OAuth-only account returns `401` instead of `500`
  (#324). Verifying against a nil password hash raised, which was a
  Sentry-flooding crash and an account-existence oracle in one, defeating the
  anti-enumeration work everywhere else. The nil case now burns the same
  constant-time comparison as the no-user branch
- `/api` is rate limited before authentication (#316), so failed authentication
  is metered. The auth plug halted with a 401 before the limiter ever ran, so
  anonymous callers had unlimited attempts, each costing a hash and an indexed
  lookup
- Minting an API key requires a verified email (#314). Verification was
  enforced in the browser hooks only, so register → token → create agent →
  provision worked without ever touching an inbox. Separately, an account
  whose trial end is missing now fails closed unless it predates the legacy
  backfill
- Avatar uploads are validated against the same media-type allowlist as turn
  images and re-checked at serve time behind `nosniff` and a sandboxing CSP
  (#407) — the upload widget's `accept` list does not constrain what gets
  stored, so a crafted client could store `text/html` and have it served from
  the application's own origin. The conversation LiveView also stopped
  decoding raw client base64 with a raising call that crashed the process, and
  the LiveView socket has an explicit maximum frame size instead of Phoenix's
  unlimited default
- Audit rows recorded from LiveView resolve the client IP the same way the API
  does (#407), instead of trusting the leftmost, client-supplied entry in
  `X-Forwarded-For`
- The sprite callback token is revoked on supervisor shutdown (#322). The
  server never trapped exits, so its teardown skipped the most common
  teardown there is — application shutdown and rebalances, i.e. every deploy —
  leaving a live sprite-scoped tenant credential outstanding until its 30-day
  expiry
- Every unscoped context function now carries the `_unsafe_` prefix (#328,
  #407), so a reader of a call site never has to go and find out whether
  tenant scoping applied; the dead unscoped surface was deleted outright. A
  custom Credo check enforces that each `_unsafe_` call site names what
  established ownership on that path

### Removed

- SSH repository clones (#228). Implemented and hardened but unreachable —
  validation has required `https://` since the schema existed, and production
  confirmed zero use. Private repos are covered by https + token secrets; the
  implementation stays in git history if demand appears
- The legacy single-tenant admin login (#327): `POST /login` read a token set
  only in test config, so in production the public route's failure mode was a
  500, and the login form it belonged to could never succeed. Real admin
  authentication is the `require_admin` hook. The four legacy routes, two
  unused auth plugs and their test scaffolding are gone
- The `deploy` git branch (#303) — the OCI manifest artifact is now the only
  deploy target
- `render.yaml` and the home-cloud cutover runbook (#409): production has been
  Kubernetes since the cutover, and both documents still asserted a deployment
  that no longer exists. `STRIPE_PUBLISHABLE_KEY`, read by nothing, is gone
  from `.env.example` (#292)

## [0.3.0] — 2026-08-02

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

[Unreleased]: https://github.com/BinaryBourbon/fountain/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/BinaryBourbon/fountain/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/BinaryBourbon/fountain/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/BinaryBourbon/fountain/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BinaryBourbon/fountain/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/BinaryBourbon/fountain/releases/tag/v0.1.0
