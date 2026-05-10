# Fountain Engineering Plan — Phase 2

> **G2 gate document.** Covers the nine architectural areas required to build Fountain as a hosted, multi-tenant rebuild of `jhgaylor/aod-ex`. Each section ends with **G2 Decisions** — the open questions originally raised for the operator, and how they were resolved on 2026-05-09. Decisions are load-bearing for sprint planning and override any earlier prose that conflicts with them.

---

## Reference baseline

`jhgaylor/aod-ex` (ADR 0002) is the reference implementation. Fountain preserves every aod-ex primitive — Environment, Secret, Vault, VaultSecret, Agent, Sandbox, Conversation, Turn, LogEvent — and adds the multi-tenancy layer on top. The delta is the focus; anything not mentioned below stays as-is from aod-ex.

**aod-ex module layout** (umbrella, two apps):

```
apps/agent_on_demand/          Phoenix server + Ecto
  lib/agent_on_demand/
    agents/                    Agent schema + context
    conversations/             Sandbox, Conversation, Turn, LogEvent, ConversationServer
    environments/              Environment, Secret + AES-GCM
    vaults/                    Vault, VaultSecret
    crypto.ex                  AES-256-GCM (single SECRETS_KEY today)
    sprite_skills.ex           Skill mounting into sprites
  lib/agent_on_demand_web/
    controllers/               REST + SSE endpoints
    plugs/admin_auth.ex        Single ADMIN_TOKEN bearer check
    plugs/session_auth.ex      Session-cookie check for LiveView
    live/                      agents_live, conversations_live, environments_live,
                               vaults_live, audit_live, help_live

apps/aod_cli/                  Burrito CLI (no Phoenix/Ecto)
  lib/aod_cli/
    api.ex                     HTTP client wrapper
    agent.ex / env.ex / vault.ex / conv.ex  subcommand dispatch
    up.ex / down.ex            Sprite host deploy (removed in Fountain)
```

---

## 1. Data Model

### 1.1 New tables

**`users`**

| column | type | notes |
|---|---|---|
| `id` | `binary_id` (UUID v7) | PK |
| `email` | `string` | unique, downcased |
| `password_hash` | `string` | bcrypt/argon2id hash |
| `email_verified_at` | `utc_datetime` | `nil` until confirmed |
| `onboarding_completed_at` | `utc_datetime` | `nil` until wizard finished |
| `max_concurrent_sandboxes` | `integer` | defaults to global config (`5`); admin-adjustable per user |
| `role` | `string` | `"user"` or `"admin"` |
| `inserted_at` / `updated_at` | `utc_datetime` | standard timestamps |

**`api_keys`**

| column | type | notes |
|---|---|---|
| `id` | `binary_id` (UUID v7) | PK |
| `user_id` | `binary_id` | FK → `users`, `delete_all` |
| `name` | `string` | user-supplied label |
| `key_hash` | `string` | SHA-256 of raw key; plaintext never stored |
| `key_prefix` | `string` | first 8 chars for display (e.g., `ftn_abc1`) |
| `last_used_at` | `utc_datetime` | updated async on each auth'd request |
| `revoked_at` | `utc_datetime` | `nil` until revoked; revoked keys are permanently invalid |
| `inserted_at` / `updated_at` | `utc_datetime` | |

**`user_data_keys`** (per-tenant envelope encryption)

| column | type | notes |
|---|---|---|
| `id` | `binary_id` (UUID v7) | PK |
| `user_id` | `binary_id` | FK → `users`, unique (one DEK per user) |
| `wrapped_key` | `binary` | 32-byte DEK encrypted by the platform master key |
| `algorithm` | `string` | `"aes_256_gcm_wrap"` at launch (env-var master key); `"kms"` reserved for the planned KMS migration sprint |
| `kms_key_id` | `string` | `nil` at launch; populated after KMS migration |
| `inserted_at` / `updated_at` | `utc_datetime` | |

**`usage_events`**

| column | type | notes |
|---|---|---|
| `id` | `bigint` autoincrement | integer PK for cheap ordered reads |
| `user_id` | `binary_id` | FK → `users`, **no** `delete_all` (billing records survive user deletion) |
| `event_type` | `string` | `turn_started`, `sandbox_provisioned`, `sandbox_terminated` |
| `resource_id` | `binary_id` | conversation_id or sandbox_id |
| `resource_type` | `string` | `"conversation"` or `"sandbox"` |
| `metadata` | `map` | runtime, model, region, duration_ms, etc. (`jsonb` on Postgres) |
| `inserted_at` | `utc_datetime` | write-once; no `updated_at` |

> **Note on PKs.** All new tables use UUID v7 (G2 decision). Generated via `Uniq.UUID` (or equivalent); time-ordered IDs improve B-tree index locality on Postgres. `usage_events` keeps a `bigint` PK because it is append-only and ordered reads benefit from a monotonic integer key.

### 1.2 Foreign key additions to existing tables

| table | new column | type | on_delete |
|---|---|---|---|
| `environments` | `user_id` | `binary_id` FK → `users` | `delete_all` |
| `agents` | `user_id` | `binary_id` FK → `users` | `delete_all` |
| `vaults` | `user_id` | `binary_id` FK → `users` | `delete_all` |
| `conversations` | `user_id` | `binary_id` FK → `users` | `delete_all` |
| `sandboxes` | `user_id` | `binary_id` FK → `users` | `nilify_all` |

`turns` and `log_events` inherit tenant scope through `conversation_id` and do not need a direct `user_id` FK.

The existing unique index `environments.name` becomes `(user_id, name)`. Same for `agents.name`, `vaults.name`. Names are only unique within a tenant.

### 1.3 Per-tenant secret envelope encryption

**aod-ex today:** a single `SECRETS_KEY` env var (32 bytes, AES-256-GCM) encrypts every `Secret.value_ciphertext` and `VaultSecret.value_ciphertext` in `crypto.ex`.

**Fountain approach — envelope encryption:**

1. At user creation, generate a random 32-byte data-encryption key (DEK).
2. Wrap the DEK using the platform master key (AES-256-GCM key-wrapping, or KMS).
3. Store the wrapped DEK in `user_data_keys.wrapped_key`.
4. When `ConversationServer` needs to decrypt secrets for a conversation, it: (a) loads the user's `user_data_keys` row, (b) unwraps the DEK using the master key, (c) holds the DEK in GenServer state for the conversation lifetime, (d) discards it on terminate.
5. `Fountain.Crypto.encrypt/decrypt` accepts a `key` argument (unchanged function signature from aod-ex's `AgentOnDemand.Crypto`); callers change only which key they pass.

A compromised tenant account exposes only that tenant's wrapped DEK. The wrapped DEK is useless without the platform master key. Rotating a tenant's key means generating a new DEK, re-encrypting all their secrets, and storing the new wrapped DEK — scoped to one row in `user_data_keys`.

**Master key at launch (G2 decision):** `MASTER_SECRETS_KEY` env var on Render, AES-256-GCM key-wrapping. KMS migration is planned for the first growth sprint after launch; the `algorithm` column on `user_data_keys` is the migration seam (re-wrap each tenant DEK under KMS, switch the column to `"kms"`, retire the env var).

### 1.4 G2 Decisions — Data Model

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-1a** | Master key storage at launch | **Env var (`MASTER_SECRETS_KEY`) at launch, planned KMS migration in first growth sprint.** Schema reserves `algorithm` and `kms_key_id` as the migration seam. |
| **OQ-1b** | SQLite or Postgres at launch | **Postgres from day one.** Removes the SQLite→Postgres cutover from the roadmap; managed Postgres backups replace any need for Litestream. See §9.1 for env vars. |
| **OQ-1c** | UUID v4 or UUID v7 | **UUID v7** for all new tables, via `Uniq.UUID` or equivalent. Better B-tree index locality on Postgres. |

---

## 2. Auth Architecture

### 2.1 Registration and email verification

```
POST /api/auth/register   { email, password }
  → validates email format + password strength
  → creates User (email_verified_at: nil)
  → generates Phoenix.Token verification token (24h TTL)
  → enqueues verification email via Swoosh
  → returns 201 { user_id, message: "Check your email to verify your account." }

GET /users/confirm/:token
  → verifies Phoenix.Token (checks TTL + signed by SECRET_KEY_BASE)
  → sets email_verified_at
  → redirects to /onboarding for new users, /dashboard for returning
```

No separate `email_verifications` DB table is needed — `Phoenix.Token.sign/4` encodes expiry in the token itself.

### 2.2 API key issuance and revocation

```
POST /api/api-keys   { name }   (requires authenticated user)
  → generates 32 random bytes, hex-encodes as "ftn_<64 hex chars>"
  → stores SHA-256(key) in api_keys.key_hash
  → stores first 8 chars in key_prefix
  → returns 201 { id, key: "<plaintext — shown once>", prefix: "ftn_xxx" }

DELETE /api/api-keys/:id   (owner or admin)
  → sets revoked_at = now(); key is immediately invalid on next request
```

The raw key is never stored or logged. A revoked key cannot be un-revoked; the user must create a new one.

### 2.3 Session management for LiveView

aod-ex has `AdminAuth` (single `ADMIN_TOKEN` bearer check) and `SessionAuth` (session cookie check with the same `ADMIN_TOKEN`). Fountain replaces both:

**`FountainWeb.Plugs.TenantAPIAuth`** — for the `:api` pipeline:
1. Extracts `Authorization: Bearer <key>` header.
2. Hashes the key with SHA-256.
3. Queries `api_keys WHERE key_hash = ? AND revoked_at IS NULL`.
4. Loads `user` via the `user_id` FK.
5. Sets `conn.assigns.current_user`.
6. Updates `last_used_at` via `Task.async` (non-blocking).
7. Returns 401 on failure.

**`FountainWeb.Plugs.TenantSessionAuth`** — for the `:browser_authenticated` pipeline:
1. Reads `user_id` from `Plug.Session`.
2. Loads user from DB.
3. Sets `conn.assigns.current_user`.
4. Redirects to `/auth/login` if absent.

**LiveView `on_mount :require_authenticated_user`** hook (in `FountainWeb.Live.Hooks`):
- Reads `current_user` from socket assigns (populated by `on_mount` from session via `Phoenix.LiveView.Auth`).
- Halts with `push_navigate` to `/auth/login` if absent.
- Halts with flash + redirect if `email_verified_at` is nil (unverified users can't use the app).

**Router pipeline structure:**
```
pipeline :api do
  plug :accepts, ["json"]
  plug FountainWeb.Plugs.TenantAPIAuth
end

pipeline :browser_authenticated do
  plug :fetch_session
  plug :fetch_live_flash
  plug FountainWeb.Plugs.TenantSessionAuth
end

pipeline :browser_public do
  plug :fetch_session
  plug :fetch_live_flash
  # No auth check — login, register, confirm pages
end
```

### 2.4 GitHub OAuth (G2 in scope)

Users can register / sign in with GitHub. Password auth remains the primary path; OAuth is additive. Library: `ueberauth` + `ueberauth_github`.

```
GET /auth/oauth/github           → redirects to GitHub
GET /auth/oauth/github/callback  → ueberauth callback
  → upsert User by primary verified email returned from GitHub
  → if new: skip email-verification (GitHub-verified email is trusted)
            create user_data_keys row, redirect to /onboarding
  → if existing: log in, redirect to /dashboard or last route
```

**`oauth_identities`** table:

| column | type | notes |
|---|---|---|
| `id` | `binary_id` (UUID v7) | PK |
| `user_id` | `binary_id` | FK → `users`, `delete_all` |
| `provider` | `string` | `"github"` (Google, etc. deferred) |
| `provider_uid` | `string` | GitHub user ID — unique per provider |
| `inserted_at` / `updated_at` | `utc_datetime` | |

Unique index on `(provider, provider_uid)`. A user may link multiple providers later; at launch one row per user is typical.

Required env vars (see §9.1): `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`.

### 2.5 Password reset (G2 in scope)

```
POST /api/auth/forgot   { email }
  → always returns 200 (no enumeration of registered emails)
  → if user exists: generates Phoenix.Token (1h TTL), enqueues reset email

GET /auth/reset/:token
  → validates Phoenix.Token; renders password-reset form

POST /auth/reset
  → validates token + new password strength
  → updates password_hash, invalidates all existing sessions for the user
  → redirects to /auth/login with flash
```

No DB table required — `Phoenix.Token` carries the expiry. Session invalidation on reset is achieved by bumping a `session_version` integer on `users` and including it in the session cookie payload.

### 2.6 Registration rate limit

aod-ex's `rate_limit.ex` is carried forward. Default: **5 registrations per IP per hour**, configurable via `config :fountain, :registration_rate_limit`. Enforced as the first plug in the registration controller. The same module gates `POST /api/auth/forgot` (5/hour/IP) to prevent reset-email spam.

### 2.7 G2 Decisions — Auth

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-2a** | OAuth at launch | **GitHub OAuth in scope.** Targets the developer audience matching aod-ex roots. Google deferred. (See §2.4.) |
| **OQ-2b** | Password reset in scope | **In scope for launch.** (See §2.5.) Email flow piggybacks on the verification email infra. |
| **OQ-2c** | API key vs. JWT | **API keys** (instantly revocable, simple to rotate). |
| **OQ-2d** | Registration rate limit | **Yes — carry forward `rate_limit.ex`.** 5/hour/IP default, also applied to forgot-password. (See §2.6.) |

---

## 3. Tenant Isolation

### 3.1 Context API changes

Every aod-ex context function that lists or fetches resources must accept and enforce a `user_id`. No cross-tenant read should ever be possible through the normal context API.

| context module | function | change |
|---|---|---|
| `Fountain.Environments` | `list_environments/0` | → `list_environments(user_id)` |
| `Fountain.Environments` | `get_environment!/1` | → `get_environment!(id, user_id)` — raises on wrong owner |
| `Fountain.Environments` | `create_environment/1` | → `create_environment(attrs, user_id)` — injects `user_id` |
| `Fountain.Agents` | `list_agents/0` | → `list_agents(user_id)` |
| `Fountain.Agents` | `get_agent!/1` | → `get_agent!(id, user_id)` |
| `Fountain.Vaults` | `list_vaults/0` | → `list_vaults(user_id)` |
| `Fountain.Vaults` | `get_vault!/1` | → `get_vault!(id, user_id)` |
| `Fountain.Conversations` | `list_conversations/0` | → `list_conversations(user_id)` |
| `Fountain.Conversations` | `get_conversation!/1` | → `get_conversation!(id, user_id)` |
| `Fountain.Conversations` | `start_conversation/1` | → validates `agent.user_id == user_id` and `vault.user_id == user_id` before starting |

All Ecto queries gain `where: [user_id: ^user_id]`. An attempt to access another tenant's resource returns `Ecto.NoResultsError`, surfaced as 404 (not 403, to avoid leaking resource existence).

### 3.2 SSE stream isolation

`ConversationController.stream/2` (SSE) in aod-ex subscribes to `PubSub` topic `"conv:<id>"` without ownership verification. In Fountain:

1. Load conversation with `get_conversation!(id, current_user.id)` — 404 if not owner.
2. Only then subscribe to the PubSub topic.
3. The `ConversationServer` broadcasts on `"conv:<id>"` as before; the isolation is enforced at subscription time.

### 3.3 Admin access

`Fountain.Accounts.User.role == "admin"` bypasses tenant scoping via a separate `Fountain.AdminContexts` module. Admins can:
- List all active sandboxes (status, user email, sprite_name).
- Read log_events for any conversation.
- They cannot read decrypted secrets or vault values (the DEK is not available outside `ConversationServer`).

### 3.4 ConversationServer key handling

`AgentOnDemand.Conversations.ConversationServer` currently derives the encryption key from the global `SECRETS_KEY` config. In Fountain, the server must:

1. Accept `user_id` in its start args.
2. In `init/1`, call `Fountain.Crypto.load_tenant_key(user_id)` which unwraps the DEK from `user_data_keys`.
3. Store the DEK in GenServer state (`%{tenant_key: dek, ...}`).
4. Pass `tenant_key` to all `Crypto.decrypt/2` calls for this conversation.
5. On `terminate/2`, pattern-match and zero the key field (best-effort in Elixir; rely on GC).

### 3.5 Admin audit log scope

Admin views read all tenants' admin-relevant events: conversation start/stop, sandbox provision/terminate, login/logout, API-key create/revoke, secret create/update (metadata only — never plaintext), billing events. Backed by an append-only `admin_audit_events` table (separate from `usage_events` so privacy/retention policy can differ).

| column | type | notes |
|---|---|---|
| `id` | `bigint` autoincrement | PK |
| `actor_user_id` | `binary_id` | who did the thing (`nil` for system events) |
| `target_user_id` | `binary_id` | which tenant the event belongs to |
| `event_type` | `string` | `conversation.started`, `api_key.revoked`, etc. |
| `metadata` | `jsonb` | resource ids, user agent, IP — no plaintext secrets |
| `inserted_at` | `utc_datetime` | write-once |

Retention: 90 days at launch (configurable). Admin LiveView filters by tenant, event type, time window.

### 3.6 G2 Decisions — Tenant Isolation

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-3a** | Reserve nullable `org_id` FK | **No.** Team features are deferred (per direction ADR 0003); add the column when teams ship. YAGNI. |
| **OQ-3b** | Admin audit log scope | **All tenants' admin-relevant events.** Dedicated `admin_audit_events` table; 90-day retention. (See §3.5.) |

---

## 4. Sandbox Quotas

> **G2 model — platform-shared Sprites account.** Fountain holds one platform-level `SPRITES_TOKEN` and uses it to provision every tenant's sandboxes. Tenants never see Sprites; Fountain pays the Sprites bill and prices its own tiers to cover it. This matches aod-ex and is the standard multi-tenant SaaS pattern. The per-conversation sandbox is the unit of isolation, provided by Sprites itself; Fountain's tenant boundary is enforced at the application layer (§3) plus a per-tenant concurrency cap to bound noisy-neighbor effects.
>
> **What we're trusting Sprites for** (verify before launch): per-sandbox isolation (no shared FS / no implicit network reachability between sandboxes in the same account); the Sprites API does not let one sandbox enumerate or read another's metadata or logs.

### 4.1 Per-tenant concurrency

1. `users.max_concurrent_sandboxes` (integer, default from `config :fountain, :default_sandbox_quota, 5`).
2. New context function `Fountain.Quotas.check_sandbox_quota!(user_id)`:
   - Counts `sandboxes WHERE user_id = ? AND status IN ('pending', 'starting', 'ready')`.
   - Raises `Fountain.Quotas.QuotaExceededError` if count >= `user.max_concurrent_sandboxes`.
3. Called inside `ConversationServer.init/1` before `Sprites.create/2`.
4. The caller (REST controller or LiveView) catches the error and returns HTTP 429 / LiveView flash.

The cap is the primary defense against a single tenant exhausting Sprites account-level limits. Admins can raise (or lower, during abuse) the cap per-user from the admin UI.

### 4.2 Sprites token handling

`SPRITES_TOKEN` remains a single platform-level secret in application config — env-var only, never persisted in the DB, never exposed to tenants or surfaced in admin UI. Each `ConversationServer` reads it from `Application.fetch_env!(:fountain, :sprites_token)` when calling `Sprites.create/2`.

**Operational guardrails** (since the blast radius of token compromise is all tenants' sandboxes):
- Set up alerting on Sprites API anomalies (sudden volume spikes, unusual regions, sandbox count > expected baseline).
- Document a token rotation runbook; rotation is a Render env-var update + restart.
- Engage Sprites to raise account-level rate limits proactively as WAU grows.

The `aod-conv-<short-id>` sprite naming prefix from aod-ex becomes `fountain-conv-<short-id>` to distinguish from any legacy aod-ex sprites on the same Sprites account.

### 4.3 Inference credentials — BYO per tenant (ADR 0008, post-G2)

In contrast to the platform-shared Sprites model (§4.2), inference provider tokens are **per-tenant**. Each user supplies their own `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, and/or `GEMINI_API_KEY` via the settings page (`/account/inference-credentials`) or the first onboarding step. Tokens live in the `inference_credentials` table, encrypted with the per-tenant DEK.

`ConversationServer.handle_continue(:provision, ...)` loads the DEK and decrypts the user's credentials at conversation start, passes the decrypted map to `runtime_module.default_env(agent, credentials)`. Plaintext credentials live only in GenServer state for the conversation lifetime.

This is a deliberate departure from §4.2's Sprites model. Reasons captured in ADR 0008: cost concentration (inference is the dominant cost line and varies wildly per turn), `CLAUDE_CODE_OAUTH_TOKEN` requires per-user provider auth by design, and there's no isolation primitive to wrap (unlike Sprites' per-sandbox isolation).

### 4.4 G2 Decisions — Quotas

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-4a** | Per-tenant Sprites credential model | **Platform-shared `SPRITES_TOKEN`.** Hidden from users (matches the Option B onboarding goal). Standard multi-tenant SaaS pattern. Per-tenant concurrency cap is the noisy-neighbor mitigation. BYO-token can return as an optional power-user feature post-launch if requested. |
| **OQ-4b** | Additional rate limits at launch | **Concurrent sandboxes only.** `usage_events` keeps recording everything; turns/hour and event-volume caps are deferred until evidence justifies them. |
| **OQ-4c** | Default concurrency cap | **5 concurrent sandboxes per tenant**, admin-adjustable per user. Now load-bearing because all tenants share one Sprites account. |
| **(post-G2)** | Inference credentials | **BYO per tenant** — see §4.3 and ADR 0008. New decision after G2 closed; supersedes any earlier implication that platform-level inference keys would be carried forward from aod-ex. |

---

## 5. Billing Surface

> **G2 model — hard Stripe gate at launch, calendar-month period.** Users without an active subscription cannot start conversations. Tenants pay for their own Sprites usage directly (BYO token, §4.1); Fountain charges for platform access (account, UI, secret storage, callback routing).

### 5.1 Usage event emission points

`Fountain.Billing.emit/5` signature:

```elixir
emit(user_id, event_type, resource_id, resource_type, metadata \\ %{})
```

Writes synchronously to `usage_events`. Used for in-app usage reporting and post-hoc analytics. (Stripe's metered usage uses a separate path — see §5.4.)

**Emission points in `ConversationServer`:**

| event_type | trigger | metadata fields |
|---|---|---|
| `sandbox_provisioned` | After `Sprites.create/2` returns `:ok` | `sprite_name`, `region`, `environment_id` |
| `turn_started` | At the start of each turn dispatch | `turn_number`, `model`, `runtime`, `conversation_id` |
| `sandbox_terminated` | On `ConversationServer.terminate/2` | `exit_code`, `duration_ms` (wall time from provisioned to terminated) |

### 5.2 Stripe integration

Library: `stripity_stripe`. One product, one or more prices (Free, Pro, etc. — pricing TBD by growth/marketing pre-launch).

| concern | implementation |
|---|---|
| Customer creation | On user verification / first login: create a Stripe Customer, store `users.stripe_customer_id` |
| Subscription | Stripe Checkout (hosted page) for upgrade; webhook updates `users.subscription_status` (`trialing`, `active`, `past_due`, `canceled`) |
| Webhook endpoint | `POST /api/stripe/webhook` — signature-verified via `Stripe.Webhook.construct_event/3` |
| Customer portal | Stripe-hosted; link from `BillingLive` for plan changes / payment method |
| Trial | Configurable; default 14-day trial on registration so users can finish onboarding before paying |

### 5.3 Hard gate

`Fountain.Billing.assert_active!(user)` raises `Fountain.Billing.SubscriptionRequiredError` unless `subscription_status in [:trialing, :active]`. Called from:

1. `ConversationServer.init/1` — blocks new conversations.
2. `POST /api/conversations` controller — returns 402 Payment Required with a body pointing at the upgrade URL.
3. LiveView `on_mount :require_active_subscription` hook on conversation/sandbox routes — flash + redirect to `/account/billing`.

Read-only routes (viewing past logs, listing resources, account settings) remain accessible during `past_due` so users can update payment without losing access to their data.

### 5.4 Usage period

Calendar month, in the user's selected timezone (default UTC). `BillingLive` aggregates `usage_events` for the current calendar month and shows running totals for sandboxes provisioned, turns started, and total wall-clock sandbox time.

### 5.5 G2 Decisions — Billing

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-5a** | Payment provider | **Stripe** via `stripity_stripe`. (See §5.2.) |
| **OQ-5b** | Hard gate vs. stub at launch | **Hard gate at launch** with a 14-day trial. Read-only access preserved during `past_due` so users can pay without data lockout. (See §5.3.) |
| **OQ-5c** | Usage period | **Calendar month** in the user's timezone. (See §5.4.) |

---

## 6. LiveView Refactor Scope

### 6.1 Existing LiveViews requiring multi-tenant changes

All existing aod-ex LiveViews must:
1. Use the `on_mount :require_authenticated_user` hook.
2. Scope every query through the multi-tenant context API (`list_*(current_user.id)`, `get_*!(id, current_user.id)`).
3. Remove any global resource listings that cross tenant boundaries.

| module | specific changes |
|---|---|
| `agents_live` | Scope list and create to `current_user.id`; the global unique name constraint becomes `(user_id, name)` |
| `conversations_live` | Scope list to user; embed `log_viewer_live` component; replace raw SSE link with in-browser viewer |
| `environments_live` | Scope list and CRUD; secret management forms decrypt/encrypt with per-tenant DEK via context API (never expose plaintext in assigns) |
| `vaults_live` | Scope list, create, CRUD for vault_secrets |
| `audit_live` | Scope to `current_user.id` for normal users; admin role gets unscoped view |

### 6.2 New LiveViews

**`FountainWeb.Live.OnboardingLive`** — post-verification wizard:
- Step 1: Welcome screen + create first Environment (name, packages, env vars).
- Step 2: Create first Agent (name, model, runtime, attach environment).
- Step 3: First Conversation — prompt input → calls `POST /api/conversations` → opens log viewer inline.
- Step 4: Done — marks `onboarding_completed_at`; redirects to `/dashboard`.
- Wizard step is persisted as a session assign; refreshing mid-wizard restores from `onboarding_completed_at` and query params. A "Skip wizard" link is present from Step 1.
- Each step's data is written to the DB on advance (not on final submit), so partial progress survives browser close.

**`FountainWeb.Live.LogViewerLive`** (embedded component + standalone route):
- On mount: loads conversation via `get_conversation!(id, current_user.id)` — 404 if not owner.
- Replays log_events from cursor: `LogEvents.list_since(conversation_id, cursor_id)` — equivalent to SSE `Last-Event-ID`.
- Subscribes to `Phoenix.PubSub` topic `"conv:<id>"`.
- Renders `output` events as monospace terminal lines (stdout green, stderr red); `stage` events as lifecycle banners.
- JS hook: auto-scrolls to bottom unless the user has scrolled up (stashed in `phx-hook`).

**`FountainWeb.Live.BillingLive`** — `/account/billing`:
- Subscription status (`trialing` / `active` / `past_due` / `canceled`) from `users.subscription_status` (Stripe webhook-synced — §5.2).
- Trial countdown when `trialing`; payment-required banner when `past_due`.
- Usage summary: `usage_events` aggregated for the current calendar month in the user's timezone (sandboxes provisioned, turns started, total wall-clock sandbox time).
- Upgrade / Manage subscription → Stripe Checkout (new) or Stripe Customer Portal (existing) via `Stripe.BillingPortal.Session.create/1`.

**`FountainWeb.Live.ApiKeysLive`** — `/account/api-keys`:
- Lists keys: `key_prefix`, `name`, `last_used_at`, `revoked_at`.
- "Create key" → name input → POST → one-time plaintext modal (copy-to-clipboard JS hook).
- "Revoke" button → DELETE → key removed from list.

**`FountainWeb.Live.AdminLive`** — `/admin` (admin role only):
- Lists all active sandboxes across tenants: sprite_name, status, user email, conversation_id.
- Link to read-only `log_viewer_live` for any conversation (no secrets exposed).
- Guarded by `on_mount :require_admin` hook.

### 6.3 New controllers

**`FountainWeb.RegistrationController`** — handles both HTML sign-up form (`GET /auth/register`, `POST /auth/register`) and JSON registration (`POST /api/auth/register`). The HTML form is the primary entry point for the onboarding funnel.

**`FountainWeb.EmailVerificationController`** — `GET /users/confirm/:token`. Validates token, sets `email_verified_at`, redirects.

**`FountainWeb.SessionController`** — extends aod-ex's `session_controller.ex`. Adds `POST /auth/register` delegating to `RegistrationController`, and a `GET /auth/logout` that clears session.

### 6.4 Onboarding wizard scope (G2)

Steps unchanged from §6.2 (Welcome + first Environment → first Agent → first Conversation → Done). The wizard is skippable from any step via a persistent "Skip wizard" link; skipping marks `onboarding_completed_at` and lets the user return via a dashboard banner.

### 6.5 Design system (G2 in scope)

Designer scope for G2 includes:
- Light + dark mode tokens (Tailwind theme + CSS custom properties).
- Primary brand palette and type scale.
- Form, button, modal, table, flash, and code-block components.
- Accessibility: WCAG AA contrast; focus states defined.

Dark mode is wired through `data-theme="dark"` on `<html>`, toggled per-user (preference stored on `users.theme_preference`).

### 6.6 Log viewer routing

Both: embedded `LogViewerLive` component inside `ConversationsLive` and a standalone `/conversations/:id/logs` route mounting the same LiveView for deep linking.

### 6.7 G2 Decisions — LiveView

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-6a** | Wizard skippable | **Yes — skippable from Step 1** (and every later step). (See §6.4.) |
| **OQ-6b** | Dark mode in G2 design scope | **In scope.** Designer ships light + dark tokens and a component library at G2. (See §6.5.) |
| **OQ-6c** | Log viewer routing | **Both** — embedded component + standalone `/conversations/:id/logs` route. (See §6.6.) |

---

## 7. CLI Distribution

### 7.1 Binary configuration

The aod-ex CLI is built via Burrito (Elixir → self-contained binary, no Erlang required on target). Fountain ships the same build pipeline with these changes:

| aspect | aod-ex | Fountain |
|---|---|---|
| Binary name | `aod` | `fountain` |
| Default base URL | `http://localhost:4000` | `https://fountain.dev` |
| Auth env var | `AOD_TOKEN` | `FOUNTAIN_API_KEY` |
| Credentials file | none | `~/.fountain/credentials` (TOML: multi-profile, see §7.4) |
| `up` / `down` subcommands | present (self-host to Sprites) | removed (Fountain is the hosted service) |

The CLI reads credentials from `~/.fountain/credentials` if `FOUNTAIN_API_KEY` is absent. The `auth login` subcommand writes this file.

### 7.2 New subcommands

| subcommand | action |
|---|---|
| `fountain auth login` | Prompts email + password, calls `POST /api/auth/token`, writes credentials to `~/.fountain/credentials` |
| `fountain auth logout` | Deletes `~/.fountain/credentials` |
| `fountain auth whoami` | Calls `GET /api/auth/me`, prints email + plan |
| `fountain keys list` | Lists API keys (prefix, name, last_used_at) |
| `fountain keys create <name>` | Creates key, prints plaintext once |
| `fountain keys revoke <id>` | Revokes key |

All existing aod-ex subcommands (`env`, `agent`, `vault`, `conv`, `run`) are preserved and updated to use `FOUNTAIN_API_KEY` / `FOUNTAIN_BASE_URL`.

### 7.3 Build and distribution

- Same Burrito + Zig cross-build pipeline as aod-ex.
- Release artifacts: `fountain-linux-x86_64`, `fountain-macos-aarch64`.
- Tag-push to `v*.*.*` triggers `.github/workflows/release.yml`.
- `FOUNTAIN_BASE_URL` defaults to the production URL via `Application.compile_env(:aod_cli, :base_url, "https://fountain.dev")`.

### 7.4 Multi-profile credentials (G2 in scope)

`~/.fountain/credentials` is an AWS-CLI-style multi-profile TOML:

```toml
[default]
api_key = "ftn_..."
base_url = "https://fountain.dev"

[staging]
api_key = "ftn_..."
base_url = "https://staging.fountain.dev"
```

Profile selection precedence: `--profile <name>` flag > `FOUNTAIN_PROFILE` env > `default`. `fountain auth login --profile staging` writes/updates the named section without disturbing other profiles.

### 7.5 G2 Decisions — CLI

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-7a** | Multi-profile support | **Yes — design the credentials file with profiles from day one** (see §7.4). Avoids a painful retrofit. |
| **OQ-7b** | Package manager distribution | **GitHub releases only at launch.** Homebrew tap is a post-launch follow-up once distribution demand is confirmed. |

---

## 8. Migration Path — Out of scope at launch

> **G2 decision: no aod-ex migration path is built for launch.** New users start fresh in Fountain. The `fountain import` CLI subcommand and `POST /api/migrate/import` endpoint described in earlier drafts are removed from launch scope; aod-ex needs no export endpoint.

Rationale: aod-ex is single-tenant self-hosted. The set of users who would migrate is small relative to the friction of building a robust migration path, and a launch-quality migration would require both a Fountain importer and an aod-ex-side export endpoint behind `ADMIN_TOKEN` (separate PR in `jhgaylor/aod-ex`). If migration becomes load-bearing post-launch, revisit as its own phase.

The CLI loses the `fountain import` subcommand listed in §7.2; remove that row before sprint 1.

### 8.1 G2 Decisions — Migration

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-8a** | aod-ex export endpoint vs. manual re-entry | **N/A — no migration in scope at launch.** |
| **OQ-8b** | Preserve aod-ex UUIDs vs. generate new | **N/A — no migration in scope at launch.** |

---

## 9. Deployment

### 9.1 `render.yaml` changes

| change | detail |
|---|---|
| Remove `ADMIN_TOKEN` | Replaced by per-user registration + API keys |
| Remove `SECRETS_KEY` | Replaced by `MASTER_SECRETS_KEY` (wraps per-tenant DEKs) |
| Add `MASTER_SECRETS_KEY` | 32 bytes, url-safe base64, `sync: false`. Generate once: `openssl rand 32 \| base64 \| tr '+/' '-_' \| tr -d '='` |
| Add `SMTP_*` vars | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM` for Swoosh email. Or `MAILGUN_API_KEY` / `POSTMARK_SERVER_TOKEN` if using a transactional provider. All `sync: false`. |
| Add `GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET` | OAuth credentials for the GitHub provider (§2.4). `sync: false`. |
| Add `STRIPE_SECRET_KEY` / `STRIPE_PUBLISHABLE_KEY` / `STRIPE_WEBHOOK_SECRET` | Stripe credentials (§5.2). `sync: false`. |
| Rename host var | `PHX_HOST` → `FOUNTAIN_DOMAIN`; used for the LiveView host and callback path prefix (§9.2) |
| Switch DB | Drop the SQLite persistent disk. Add a managed Postgres database (`DATABASE_URL`, `sync: false`). G2 chose Postgres day-one (OQ-1b). |
| Add `BILLING_WEBHOOK_URL` | Optional, `sync: false`. Used for downstream consumers of `usage_events`; not required for Stripe (Stripe webhooks have their own endpoint). |
| `SPRITES_TOKEN` | Unchanged — platform-level, tenants never see it. Env-var only; never persist. |
| Region | `oregon` only at launch (OQ-9c). |

### 9.2 Callback skill routing — path prefix + token (G2)

The `aod` callback skill injected into each sprite must route to the correct tenant's `ConversationServer`. G2 chose **defense in depth: path scopes routing, token authenticates**.

At sandbox provisioning, `ConversationServer`:
1. Generates a short-lived token signed with `Phoenix.Token`, scoped to `(user_id, conversation_id)`, TTL = conversation lifetime + 10-minute buffer.
2. Sets two env vars on the sprite:
   - `FOUNTAIN_CALLBACK_URL=https://fountain.dev/api/callback/<conversation_id>`
   - `FOUNTAIN_CALLBACK_TOKEN=<signed_token>`

`POST /api/callback/:conversation_id`:
1. Extract `:conversation_id` from path.
2. Verify `Authorization: Bearer <token>` against `Phoenix.Token.verify/4` with the conversation lifetime as max-age.
3. Confirm the verified token's `(user_id, conversation_id)` matches the loaded conversation.
4. Reject (401) if any check fails. Both layers must agree.

This eliminates two whole classes of cross-tenant callback bugs: a forged path can't authenticate, and a leaked token can't be replayed against a different conversation.

The `aod` skill in `priv/sprite_skills/aod/SKILL.md` must be updated to use `FOUNTAIN_CALLBACK_URL` and `FOUNTAIN_CALLBACK_TOKEN` in place of `AOD_BASE_URL` + `AOD_TOKEN`.

### 9.3 Sprites deploy changes

`aod up` / `aod down` (deploying aod-ex itself to a Sprite as the host) are removed from Fountain's CLI. Fountain is deployed to Render (or a comparable platform), not Sprites. The `aod-host-<unix-ts>` sprite naming convention is retired.

Per-conversation sprites continue with the prefix pattern, changed from `aod-conv-<id>` to `fountain-conv-<id>` to distinguish from any legacy aod-ex sprites on the same Sprites account.

`render.yaml` `preDeployCommand` remains `_build/prod/rel/fountain/bin/migrate` — Ecto migrations run before each deploy.

### 9.4 G2 Decisions — Deployment

| ID | Question | Decision (2026-05-09) |
|---|---|---|
| **OQ-9a** | Callback routing | **Both — path prefix + token.** Defense in depth. (See §9.2.) |
| **OQ-9b** | Litestream | **N/A** — Postgres chosen at OQ-1b; managed Postgres backups replace Litestream. |
| **OQ-9c** | Region | **Single region (Oregon) at launch.** Multi-region is a post-100-WAU concern. |
| **OQ-9d** | Master key launch posture | **`MASTER_SECRETS_KEY` env var at launch, planned KMS migration in first growth sprint.** Same call as OQ-1a. (See §1.3 for migration seam.) |

---

## G2 Decisions Summary (resolved 2026-05-09)

All 26 open questions raised in earlier drafts of this plan are resolved below. Each decision is restated in its section above; this is the at-a-glance index for sprint planning.

| ID | Section | Decision |
|---|---|---|
| OQ-1a | Data Model | Env-var `MASTER_SECRETS_KEY` at launch; planned KMS migration in first growth sprint |
| OQ-1b | Data Model | **Postgres from day one** (drops the SQLite path entirely) |
| OQ-1c | Data Model | UUID v7 for all new tables |
| OQ-2a | Auth | **GitHub OAuth in scope** for launch (Google deferred) |
| OQ-2b | Auth | Password reset **in scope** for launch |
| OQ-2c | Auth | API keys (not JWT) |
| OQ-2d | Auth | Rate limit registration (and forgot-password): 5/hour/IP |
| OQ-3a | Tenant Isolation | **Do not** reserve `org_id` FK; add when teams ship |
| OQ-3b | Tenant Isolation | All-tenant admin audit log; dedicated `admin_audit_events` table; 90-day retention |
| OQ-4a | Quotas | **Platform-shared `SPRITES_TOKEN`** (hidden from users); per-tenant cap is the noisy-neighbor mitigation |
| OQ-4b | Quotas | Concurrent-sandbox cap only at launch; turns/hour deferred |
| OQ-4c | Quotas | Default `max_concurrent_sandboxes = 5`; admin-adjustable per user |
| OQ-5a | Billing | Stripe via `stripity_stripe` |
| OQ-5b | Billing | **Hard gate at launch** with 14-day trial; read-only access preserved during `past_due` |
| OQ-5c | Billing | Calendar month, in user's timezone |
| OQ-6a | LiveView | Wizard skippable from any step |
| OQ-6b | LiveView | **Dark mode + design system in G2 design scope** |
| OQ-6c | LiveView | Both embedded component + standalone `/conversations/:id/logs` route |
| OQ-7a | CLI | Multi-profile credentials file from day one |
| OQ-7b | CLI | GitHub releases only at launch (Homebrew tap deferred) |
| OQ-8a | Migration | **N/A — no aod-ex migration in scope at launch** |
| OQ-8b | Migration | N/A — see OQ-8a |
| OQ-9a | Deployment | **Path prefix + token** for callback routing (defense in depth) |
| OQ-9b | Deployment | N/A — Postgres chosen; managed backups replace Litestream |
| OQ-9c | Deployment | Single region (Oregon) at launch |
| OQ-9d | Deployment | Same as OQ-1a (env var at launch, KMS later) |

### Decisions worth promoting to ADRs

These three decisions are load-bearing across sprints and should land as ADRs in `decisions/` before sprint 1 starts:

1. **Postgres day-one** (OQ-1b) — drops the SQLite path from the roadmap; affects every infra and schema choice downstream.
2. **Platform-shared Sprites token model** (OQ-4a) — defines the trust boundary, the cost model, and the per-tenant cap as a load-bearing safety mechanism.
3. **Hard Stripe billing gate at launch** (OQ-5b) — defines launch revenue model, the trial flow, and the `past_due` UX.

Other decisions (OAuth scope, dark mode, no migration) are scope calls captured here and don't need ADRs unless they become contentious.

---

*Document produced by the general-purpose-engineer per the Phase 2 brief; G2 decisions resolved by the operator on 2026-05-09.*
