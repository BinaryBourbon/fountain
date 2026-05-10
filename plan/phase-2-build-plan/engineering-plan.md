# Fountain Engineering Plan — Phase 2

> **G2 gate document.** Covers the nine architectural areas required to build Fountain as a hosted, multi-tenant rebuild of `jhgaylor/aod-ex`. Each section ends with **Open Questions** — items that require a human decision before implementation begins. No direction is taken on open questions here; they are flagged for the operator to resolve at G2.

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
| `id` | `binary_id` (UUID) | PK |
| `email` | `string` | unique, downcased |
| `password_hash` | `string` | bcrypt/argon2id hash |
| `email_verified_at` | `utc_datetime` | `nil` until confirmed |
| `onboarding_completed_at` | `utc_datetime` | `nil` until wizard finished |
| `max_concurrent_sandboxes` | `integer` | defaults to global config |
| `role` | `string` | `"user"` or `"admin"` |
| `inserted_at` / `updated_at` | `utc_datetime` | standard timestamps |

**`api_keys`**

| column | type | notes |
|---|---|---|
| `id` | `binary_id` | PK |
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
| `id` | `binary_id` | PK |
| `user_id` | `binary_id` | FK → `users`, unique (one DEK per user) |
| `wrapped_key` | `binary` | 32-byte DEK encrypted by the platform master key |
| `algorithm` | `string` | `"aes_256_gcm_wrap"` or `"kms"` |
| `kms_key_id` | `string` | `nil` unless KMS mode |
| `inserted_at` / `updated_at` | `utc_datetime` | |

**`usage_events`**

| column | type | notes |
|---|---|---|
| `id` | `bigint` autoincrement | integer PK for cheap ordered reads |
| `user_id` | `binary_id` | FK → `users`, **no** `delete_all` (billing records survive user deletion) |
| `event_type` | `string` | `turn_started`, `sandbox_provisioned`, `sandbox_terminated` |
| `resource_id` | `binary_id` | conversation_id or sandbox_id |
| `resource_type` | `string` | `"conversation"` or `"sandbox"` |
| `metadata` | `map` | runtime, model, region, duration_ms, etc. |
| `inserted_at` | `utc_datetime` | write-once; no `updated_at` |

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

### 1.4 Open Questions — Data Model

| ID | Question | Blocks |
|---|---|---|
| **OQ-1a** | In-process `MASTER_SECRETS_KEY` env var, or cloud KMS (AWS KMS / GCP KMS)? KMS is hardware-backed and auditable; env var is simpler at launch but concentrates risk on the server. | Security architecture |
| **OQ-1b** | SQLite (WAL mode, Render persistent disk) for launch, or Postgres? At 100 WAU SQLite is fine; beyond that, Ecto makes migration achievable but needs a planned cutover. | Deployment |
| **OQ-1c** | UUID v4 (aod-ex default) or UUID v7 (time-ordered, better index locality) for new tables? | Schema design |

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

### 2.4 Open Questions — Auth

| ID | Question | Blocks |
|---|---|---|
| **OQ-2a** | OAuth / social login (Google, GitHub) at launch? Lowers sign-up friction but adds scope. | Auth UX design |
| **OQ-2b** | Password reset flow in scope for launch? Requires email flow (forgot → token → reset). Low effort if email infra exists. | Auth UX design |
| **OQ-2c** | API key or JWT for machine auth? API keys are simple and instantly revocable; JWTs are stateless but require a revocation list. Recommendation: API keys. | CLI design |
| **OQ-2d** | Rate limiting on `POST /api/auth/register` to prevent spam signups? aod-ex has `rate_limit.ex` — carry forward and tune. | Security |

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

### 3.5 Open Questions — Tenant Isolation

| ID | Question | Blocks |
|---|---|---|
| **OQ-3a** | Reserve an optional `org_id` FK column (null at launch) on `environments`, `agents`, `vaults` to allow future team features without a schema migration? Costs nothing now; avoids a disruptive later migration. | Schema design |
| **OQ-3b** | Admin audit log scope: all tenants' events, or only conversations flagged by support? | Admin UI design |

---

## 4. Sandbox Quotas

### 4.1 Per-tenant concurrency

1. `users.max_concurrent_sandboxes` (integer, default from `config :fountain, :default_sandbox_quota, 3`).
2. New context function `Fountain.Quotas.check_sandbox_quota!(user_id)`:
   - Counts `sandboxes WHERE user_id = ? AND status IN ('pending', 'starting', 'ready')`.
   - Raises `Fountain.Quotas.QuotaExceededError` if count >= `user.max_concurrent_sandboxes`.
3. Called inside `ConversationServer.init/1` before `Sprites.create/2`.
4. The caller (REST controller or LiveView) catches the error and returns HTTP 429 / LiveView flash.

### 4.2 Sprites token pooling

`SPRITES_TOKEN` remains a single platform-level secret in application config. Tenants never see it. Each `ConversationServer` uses the platform token when calling `Sprites.create/2`. This is unchanged from aod-ex's model.

The `aod-conv-<short-id>` sprite naming prefix is preserved. Fountain prefixes sprites with `fountain-conv-<short-id>` to distinguish from any legacy aod-ex sprites on the same Sprites account.

### 4.3 Open Questions — Quotas

| ID | Question | Blocks |
|---|---|---|
| **OQ-4a** | Does Sprites support per-tenant credential delegation (separate tokens per user)? If yes, use it for stronger isolation. | Sprites integration |
| **OQ-4b** | Additional rate limits beyond sandbox count — e.g., turns/hour or log_event volume/day? `usage_events` table supports it; enforcement is a later sprint. | Billing/quotas design |
| **OQ-4c** | Default quota value? `3` concurrent sandboxes is a placeholder; confirm based on per-sprite cost and expected user behavior. | Config |

---

## 5. Billing Surface

### 5.1 Usage event emission points

`Fountain.Billing.emit/5` signature:

```elixir
emit(user_id, event_type, resource_id, resource_type, metadata \\ %{})
```

Writes synchronously to `usage_events`. If `BILLING_WEBHOOK_URL` is configured, spawns a `Task` to POST the event as JSON to that URL (fire-and-forget at launch; no retry).

**Emission points in `ConversationServer`:**

| event_type | trigger | metadata fields |
|---|---|---|
| `sandbox_provisioned` | After `Sprites.create/2` returns `:ok` | `sprite_name`, `region`, `environment_id` |
| `turn_started` | At the start of each turn dispatch | `turn_number`, `model`, `runtime`, `conversation_id` |
| `sandbox_terminated` | On `ConversationServer.terminate/2` | `exit_code`, `duration_ms` (wall time from provisioned to terminated) |

### 5.2 Webhook stub

`config/config.exs` (and `runtime.exs`):
```
config :fountain, :billing_webhook_url, System.get_env("BILLING_WEBHOOK_URL")
```

The webhook payload is a JSON object matching the `usage_events` row. A `billing_delivery_log` table for reliable delivery with retries is a post-launch addition.

### 5.3 Open Questions — Billing

| ID | Question | Blocks |
|---|---|---|
| **OQ-5a** | Stripe or another payment provider? The stub is provider-agnostic, but subscription gate and Checkout integration is provider-specific. | Billing UI |
| **OQ-5b** | Hard billing gate at launch (block users when over quota or unpaid), or usage-tracking-only stub? If stub only, webhook URL can be left empty at launch. | Sprint planning |
| **OQ-5c** | Usage period for the billing UI — calendar month or rolling 30 days? | Billing UI |

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
- Current plan display (stub: "Free" tier).
- Usage summary: `usage_events` aggregated for current period (sandboxes provisioned, turns started, total).
- Upgrade CTA → external Stripe Checkout link (stub until Stripe integration sprint).

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

### 6.4 Open Questions — LiveView

| ID | Question | Blocks |
|---|---|---|
| **OQ-6a** | Is the onboarding wizard skippable from Step 1? Recommend yes — aod-ex migrators and API-first users will resent being gated. | UX design |
| **OQ-6b** | Dark mode / Tailwind design system in scope for G2 design work, or post-launch? | Design scope |
| **OQ-6c** | Is `log_viewer_live` embedded in `conversations_live` as a component, or a separate route for deep-linking? Recommend both: embedded component + `/conversations/:id/logs` standalone URL. | Navigation design |

---

## 7. CLI Distribution

### 7.1 Binary configuration

The aod-ex CLI is built via Burrito (Elixir → self-contained binary, no Erlang required on target). Fountain ships the same build pipeline with these changes:

| aspect | aod-ex | Fountain |
|---|---|---|
| Binary name | `aod` | `fountain` |
| Default base URL | `http://localhost:4000` | `https://fountain.dev` |
| Auth env var | `AOD_TOKEN` | `FOUNTAIN_API_KEY` |
| Credentials file | none | `~/.fountain/credentials` (TOML: `api_key`, `base_url`) |
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
| `fountain import` | See Section 8 |

All existing aod-ex subcommands (`env`, `agent`, `vault`, `conv`, `run`) are preserved and updated to use `FOUNTAIN_API_KEY` / `FOUNTAIN_BASE_URL`.

### 7.3 Build and distribution

- Same Burrito + Zig cross-build pipeline as aod-ex.
- Release artifacts: `fountain-linux-x86_64`, `fountain-macos-aarch64`.
- Tag-push to `v*.*.*` triggers `.github/workflows/release.yml`.
- `FOUNTAIN_BASE_URL` defaults to the production URL via `Application.compile_env(:aod_cli, :base_url, "https://fountain.dev")`.

### 7.4 Open Questions — CLI

| ID | Question | Blocks |
|---|---|---|
| **OQ-7a** | Multi-profile support (`--profile staging`)? Useful for developers running a local Fountain instance alongside production. Low cost at credentials-file design time. | CLI design |
| **OQ-7b** | Homebrew tap or other package manager distribution? Not required at launch; GitHub releases are sufficient. | Distribution |

---

## 8. Migration Path

### 8.1 REST endpoint

`POST /api/migrate/import` (authenticated — requires verified user):

Accepts a JSON body in aod-ex export format:

```json
{
  "environments": [
    {
      "name": "...", "packages": {...}, "env_vars": {...},
      "networking_type": "...", "networking_config": {...},
      "setup_script": "...", "repositories": [...],
      "secrets": [{ "key": "...", "value": "<plaintext>" }]
    }
  ],
  "vaults": [
    {
      "name": "...", "description": "...",
      "secrets": [{ "key": "...", "value": "<plaintext>" }]
    }
  ],
  "agents": [
    {
      "name": "...", "model": "...", "runtime": "...",
      "system": "...", "skills": [...], "mcp_servers": {...},
      "environment_name": "..."
    }
  ]
}
```

Processing steps:
1. Validate all objects (required fields, no cross-tenant references).
2. Create each resource under `current_user.id` with new UUIDs.
3. Re-encrypt all secret values with the user's per-tenant DEK.
4. Resolve `environment_name` references in agents to the newly created environment IDs.
5. Return `{ created: { environments: N, agents: N, vaults: N }, errors: [...] }`.

Conversations and log_events are not migrated (ephemeral; sprites are gone).

### 8.2 CLI command

`fountain import --source-url <aod-url> --source-token <token>`:

1. Fetches environments, agents, vaults from `<source-url>` with `<source-token>`.
2. Fetches secrets from each environment and vault.
3. Assembles the import payload.
4. POSTs to `POST /api/migrate/import` on the configured Fountain instance.

**Important caveat on secrets:** aod-ex's current API does not return plaintext secret values (by design). Migration of secrets requires one of:
- **(a)** A privileged `GET /api/export` endpoint added to aod-ex, protected by `ADMIN_TOKEN`, that returns plaintext values for a one-time export. This is the cleanest path for self-hosted operators.
- **(b)** Manual secret re-entry in Fountain after import (environments and agents import cleanly; secrets are blank).

### 8.3 Open Questions — Migration

| ID | Question | Blocks |
|---|---|---|
| **OQ-8a** | Should aod-ex gain a privileged export endpoint, or is manual secret re-entry acceptable? Given aod-ex is self-hosted, adding an export endpoint behind `ADMIN_TOKEN` is operator-controlled and acceptable. | Migration UX |
| **OQ-8b** | Preserve aod-ex UUIDs in Fountain (collision risk in shared DB) or always generate new ones? Recommendation: new UUIDs; store old ID in `metadata.aod_ex_id` for traceability. | Migration design |

---

## 9. Deployment

### 9.1 `render.yaml` changes

| change | detail |
|---|---|
| Remove `ADMIN_TOKEN` | Replaced by per-user registration + API keys |
| Remove `SECRETS_KEY` | Replaced by `MASTER_SECRETS_KEY` (wraps per-tenant DEKs) |
| Add `MASTER_SECRETS_KEY` | 32 bytes, url-safe base64, `sync: false`. Generate once: `openssl rand 32 \| base64 \| tr '+/' '-_' \| tr -d '='` |
| Add `SMTP_*` vars | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM` for Swoosh email. Or `MAILGUN_API_KEY` / `POSTMARK_SERVER_TOKEN` if using a transactional provider. All `sync: false`. |
| Rename host var | `PHX_HOST` → `FOUNTAIN_DOMAIN`; used for both the LiveView host and the callback skill base URL |
| Resize persistent disk | 1 GB → 4 GB for multi-tenant SQLite data volume |
| Add `BILLING_WEBHOOK_URL` | Optional, `sync: false`. Leave empty at launch if billing is stub-only. |
| `SPRITES_TOKEN` | Unchanged — platform-level, tenants never see it |

### 9.2 `AOD_PUBLIC_URL` / callback skill routing

In aod-ex, `AOD_PUBLIC_URL` is a single URL for all callbacks from sprites. In Fountain, the `aod` callback skill injected into each sprite must route to the correct tenant's context.

**Option A — tenant-namespaced path:** The sprite receives `FOUNTAIN_CALLBACK_URL=https://fountain.dev/api/callback/<user_id>`. The callback controller extracts `user_id` from the path and loads context without a separate token (relies on HTTPS + sprite-level isolation).

**Option B — tenant-scoped bearer token (recommended):** At sandbox provisioning time, `ConversationServer` generates a short-lived token signed with `Phoenix.Token` (TTL: conversation lifetime + buffer), scoped to `(user_id, conversation_id)`. The sprite receives `FOUNTAIN_CALLBACK_URL=https://fountain.dev/api/callback` and `FOUNTAIN_CALLBACK_TOKEN=<signed_token>`. The callback controller validates the token before processing. More secure; token rotation is possible.

The `aod` skill in `priv/sprite_skills/aod/SKILL.md` must be updated to use `FOUNTAIN_CALLBACK_URL` and `FOUNTAIN_CALLBACK_TOKEN` in place of `AOD_BASE_URL` + `AOD_TOKEN`.

### 9.3 Sprites deploy changes

`aod up` / `aod down` (deploying aod-ex itself to a Sprite as the host) are removed from Fountain's CLI. Fountain is deployed to Render (or a comparable platform), not Sprites. The `aod-host-<unix-ts>` sprite naming convention is retired.

Per-conversation sprites continue with the prefix pattern, changed from `aod-conv-<id>` to `fountain-conv-<id>` to distinguish from any legacy aod-ex sprites on the same Sprites account.

`render.yaml` `preDeployCommand` remains `_build/prod/rel/fountain/bin/migrate` — Ecto migrations run before each deploy.

### 9.4 Open Questions — Deployment

| ID | Question | Blocks |
|---|---|---|
| **OQ-9a** | Callback routing: Option A (path prefix) or Option B (short-lived token)? Option B is more secure; Option A is simpler. | Security design |
| **OQ-9b** | Litestream replication to S3 for point-in-time recovery of SQLite? Render persistent disks are not replicated. Low operational cost to add at launch. | Reliability |
| **OQ-9c** | Single-region (Oregon) for launch, or multi-region from day one? Latency vs. operational complexity trade-off. | Infrastructure |
| **OQ-9d** | `MASTER_SECRETS_KEY` env var at launch, with planned KMS migration, or KMS from day one? Recommendation: env var at launch, migrate to KMS in first growth sprint. | Security |

---

## Summary of Open Questions for G2

The table below consolidates all open questions. The operator must resolve each before the corresponding implementation sprint begins.

| ID | Section | Question | Blocks |
|---|---|---|---|
| OQ-1a | Data Model | In-process master key vs. cloud KMS? | Security arch |
| OQ-1b | Data Model | SQLite at launch or Postgres? | Deployment |
| OQ-1c | Data Model | UUID v4 vs UUID v7 for new tables? | Schema design |
| OQ-2a | Auth | OAuth / social login at launch? | Auth UX |
| OQ-2b | Auth | Password reset in scope? | Auth UX |
| OQ-2c | Auth | API key vs. JWT for machine auth? | CLI design |
| OQ-2d | Auth | Rate limiting on registration? | Security |
| OQ-3a | Tenant Isolation | Reserve `org_id` FK for future team features? | Schema design |
| OQ-3b | Tenant Isolation | Admin audit log scope? | Admin UI |
| OQ-4a | Quotas | Per-tenant Sprites token delegation available? | Sprites integration |
| OQ-4b | Quotas | Additional rate limits (turns/hour)? | Billing design |
| OQ-4c | Quotas | Default quota value? | Config |
| OQ-5a | Billing | Stripe vs. other provider? | Billing UI |
| OQ-5b | Billing | Billing gate at launch, or usage-tracking stub? | Sprint planning |
| OQ-5c | Billing | Usage period: calendar month or rolling 30 days? | Billing UI |
| OQ-6a | LiveView | Onboarding wizard skippable? | UX design |
| OQ-6b | LiveView | Dark mode / branding in G2 design scope? | Design scope |
| OQ-6c | LiveView | Embedded vs. standalone log viewer routes? | Navigation |
| OQ-7a | CLI | Multi-profile credential support? | CLI design |
| OQ-7b | CLI | Package manager distribution? | Distribution |
| OQ-8a | Migration | aod-ex export endpoint vs. manual re-entry? | Migration UX |
| OQ-8b | Migration | Preserve aod-ex UUIDs or generate new? | Migration design |
| OQ-9a | Deployment | Callback routing: path vs. token? | Security |
| OQ-9b | Deployment | Litestream at launch? | Reliability |
| OQ-9c | Deployment | Single-region or multi-region at launch? | Infrastructure |
| OQ-9d | Deployment | `MASTER_SECRETS_KEY` env var or KMS from day one? | Security |

---

*Document produced by the general-purpose-engineer per the Phase 2 brief. No directions are taken on open questions — those calls belong to the human operator at G2.*
