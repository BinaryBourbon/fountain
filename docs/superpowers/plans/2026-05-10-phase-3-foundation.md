# Phase 3 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the aod-ex umbrella into the Fountain codebase with Postgres, envelope encryption, user accounts, billing scaffolding, and GitHub OAuth wiring.

**Architecture:** Elixir umbrella with two apps (`fountain` Phoenix server, `fountain_cli` Burrito CLI). SQLite replaced with managed Postgres (Render) using `DATABASE_URL`. AES-256-GCM envelope encryption: platform master key wraps per-tenant DEKs stored in `user_data_keys`. User auth via bcrypt passwords and GitHub OAuth; API keys use SHA-256 hashed tokens. Stripe billing gate with 14-day trial baked into the `users` table.

**Tech Stack:** Elixir 1.19 / OTP 28, Phoenix 1.8, Ecto 3.13, PostgreSQL 16, bcrypt_elixir, uniq (UUID v7), stripity_stripe, swoosh + gen_smtp, ueberauth + ueberauth_github, mimic (test stubs)

---

### Task 1: Scaffold umbrella from aod-ex

**Files:**
- Create: `mix.exs` (root umbrella)
- Create: `apps/fountain/mix.exs`
- Create: `apps/fountain_cli/mix.exs`
- Modify: all `lib/**/*.ex` — rename `AgentOnDemand` → `Fountain`, `AgentOnDemandWeb` → `FountainWeb`, `AodCli` → `FountainCli`

- [x] Copy aod-ex umbrella structure into fountain repo
- [x] Bulk rename all module references via sed
- [x] Update root `mix.exs` for umbrella with fountain + fountain_server releases
- [x] Update `apps/fountain/mix.exs`: remove `ecto_sqlite3`, add `postgrex`; add new deps
- [x] Update `apps/fountain_cli/mix.exs`: rename module, update `sprites` dep to `github: "superfly/sprites-ex"`
- [x] Change `Fountain.Repo` adapter to `Ecto.Adapters.Postgres`
- [x] Guard OpenTelemetry calls in `application.ex` with `if Application.spec(:opentelemetry_phoenix)` (rebar3 bare compile issues in dev)
- [x] Mark `opentelemetry`, `opentelemetry_exporter`, `opentelemetry_phoenix`, `opentelemetry_ecto`, `opentelemetry_telemetry` as `only: :prod`

### Task 2: Postgres config + Docker Compose

**Files:**
- Modify: `config/dev.exs`, `config/test.exs`, `config/runtime.exs`, `config/config.exs`
- Create: `docker-compose.yml`

- [x] `dev.exs`: `url: "postgres://postgres:postgres@localhost:5432/fountain_dev"`
- [x] `test.exs`: same URL `fountain_test`, `pool: Ecto.Adapters.SQL.Sandbox`
- [x] `runtime.exs`: reads `DATABASE_URL`, `MASTER_SECRETS_KEY` (replaces `SECRETS_KEY`), GitHub OAuth, Stripe, SMTP, `FOUNTAIN_DOMAIN`
- [x] Create `docker-compose.yml` with `postgres:16` service on port 5432

### Task 3: render.yaml

**Files:**
- Modify: `render.yaml`

- [x] Remove `ADMIN_TOKEN`, `SECRETS_KEY`, SQLite disk
- [x] Add `MASTER_SECRETS_KEY` (sync: false), `DATABASE_URL` (fromDatabase), `GITHUB_OAUTH_CLIENT_ID/SECRET`, `STRIPE_*`, `SMTP_*`, `FOUNTAIN_DOMAIN`
- [x] Add `databases:` block for managed Postgres 16

### Task 4: Migrations — 9 existing + 7 new

**Files:**
- Create: `apps/fountain/priv/repo/migrations/20260510100000_create_users.exs` through `20260510100006_add_user_id_to_tenant_tables.exs`
- Modify: `20260504000000_rehydrate_agent_skills.exs` (SQLite `?` → Postgres `$1/$2/$3`)

- [x] Copy 9 existing migrations from aod-ex; rename module prefix to `Fountain.Repo.Migrations.*`
- [x] Fix `rehydrate_agent_skills`: `?` → `$1/$2/$3`; add `decode/1` map/list clauses for Postgres jsonb
- [x] `create_users`: uuid_v7 PK, email (unique), password_hash, email_verified_at, onboarding_completed_at, max_concurrent_sandboxes (default 5), role (default "user"), stripe_customer_id, subscription_status (default "trialing"), trial_ends_at, session_version (default 0), timestamps
- [x] `create_oauth_identities`: uuid_v7 PK, provider, provider_uid, user_id FK (delete_all), unique on (provider, provider_uid), timestamps
- [x] `create_api_keys`: uuid_v7 PK, name, key_hash (unique), key_prefix, last_used_at, revoked_at, user_id FK (delete_all), timestamps
- [x] `create_user_data_keys`: uuid_v7 PK, wrapped_key (binary), algorithm, kms_key_id, user_id FK unique (delete_all), timestamps
- [x] `create_usage_events`: bigint PK (auto-increment), user_id FK (no cascade), event_type, resource_id, resource_type, metadata (jsonb), inserted_at only
- [x] `create_admin_audit_events`: bigint PK, actor_user_id, target_user_id, event_type, metadata (jsonb), inserted_at only
- [x] `add_user_id_to_tenant_tables`: add user_id to environments/agents/vaults/conversations (FK delete_all), sandboxes (FK nilify_all); drop old `:name` unique indexes; add scoped `(user_id, name)` unique indexes

### Task 5: Fountain.Crypto

**Files:**
- Modify: `apps/fountain/lib/fountain/crypto.ex`
- Create: `apps/fountain/test/fountain/crypto_test.exs`

- [x] Replace old single-key `Crypto` with envelope encryption
- [x] `encrypt(plaintext, key, aad \\ "fountain.secret")` → `iv(12) <> tag(16) <> ciphertext`
- [x] `decrypt(blob, key, aad \\ "fountain.secret")` → `{:ok, plaintext} | :error`
- [x] `generate_dek/0` → 32 random bytes
- [x] `wrap_dek(dek)` → encrypts DEK with `MASTER_SECRETS_KEY`, stores in `user_data_keys`
- [x] `load_tenant_key(user_id)` → loads `UserDataKey`, unwraps DEK with master key
- [x] 13 unit tests: round-trip, wrong key, wrong aad, empty/truncated input, generate_dek, wrap_dek

### Task 6: Fountain.Accounts

**Files:**
- Create: `apps/fountain/lib/fountain/accounts/user.ex`
- Create: `apps/fountain/lib/fountain/accounts/api_key.ex`
- Create: `apps/fountain/lib/fountain/accounts/user_data_key.ex`
- Create: `apps/fountain/lib/fountain/accounts/oauth_identity.ex`
- Create: `apps/fountain/lib/fountain/accounts.ex`
- Create: `apps/fountain/test/fountain/accounts_test.exs`

- [x] `User` schema: all fields from migration; `registration_changeset/2` (email format, password min 8, hash); `oauth_registration_changeset/2`; `billing_changeset/2`; `invalidate_sessions_changeset/1`
- [x] `ApiKey` schema: name, key_hash, key_prefix, last_used_at, revoked_at; unique constraint on key_hash
- [x] `UserDataKey` schema: wrapped_key, algorithm, kms_key_id; unique constraint on user_id
- [x] `OauthIdentity` schema: provider, provider_uid; unique constraint on (provider, provider_uid)
- [x] `Accounts.get_user_by_email/1`: downcases email, `Repo.get_by`
- [x] `Accounts.register_user/1`: transaction — insert user + generate DEK + wrap DEK + insert UserDataKey
- [x] `Accounts.create_api_key/2`: generates `"ftn_<64 hex chars>"`, stores SHA-256 hash + 8-char prefix
- [x] `Accounts.revoke_api_key/2`: sets `revoked_at`
- [x] `Accounts.get_user_by_api_key/1`: hashes raw key, queries with JOIN, requires `revoked_at IS NULL`
- [x] Unit tests: changeset validations, `hash_key/1` determinism

### Task 7: Cleanup and deps

**Files:**
- Modify: `apps/fountain/test/test_helper.exs`
- Modify: `.env.example`
- Modify: `apps/fountain/mix.exs` (test alias)

- [x] `test_helper.exs`: guard `Sandbox.mode` call with `if Process.whereis(Fountain.Repo)`
- [x] Test alias: remove `ecto.create --quiet`, `ecto.migrate --quiet` from `test:` alias (Postgres managed externally)
- [x] `.env.example`: updated to Fountain vars (DATABASE_URL, MASTER_SECRETS_KEY, GitHub OAuth, Stripe, SMTP, Claude auth, OpenAI, Gemini)

---

**Verification:** `mix test apps/fountain/test/fountain/crypto_test.exs apps/fountain/test/fountain/accounts_test.exs` → 29 tests, 0 failures
