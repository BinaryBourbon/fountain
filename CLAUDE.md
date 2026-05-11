# CLAUDE.md — Contributor Guide

This file is read by Claude Code (and other AI coding tools) at session start. Keep it accurate — stale guidance misleads every downstream dispatch.

## Quick start

```bash
mise install                        # pin Erlang/OTP 28 + Elixir 1.19.2
mix deps.get
mix setup                           # dev DB: create + migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test                            # full suite (~200 tests)
mix precommit                       # same checks CI runs
```

See [SETUP.md](SETUP.md) for full workstation bootstrap (Postgres, OAuth keys, etc.).

## Repo layout

```
fountain/                  umbrella root
  apps/
    fountain/              core business logic (Elixir OTP app)
      lib/fountain/        contexts: Accounts, Agents, Environments, Vaults,
      |                              Conversations, Billing, Crypto, Audit,
      |                              Substitution
      lib/fountain_web/    Phoenix: controllers, LiveView, plugs, router
      test/fountain/       context unit tests (async: true, DataCase)
      test/fountain_web/   controller/LiveView integration tests
      test/support/        DataCase, ConnCase, factory.ex
  config/
    config.exs             shared config
    dev.exs                dev overrides
    test.exs               test overrides (pool_size: 20, test-mode flags)
    prod.exs               prod overrides
  .github/workflows/ci.yml CI pipeline
  decisions/               ADRs (Architecture Decision Records)
  docs/                    source for the public MkDocs site
```

## Architecture: the four primitives

| Primitive | Purpose |
|---|---|
| **Environment** | Baseline set of encrypted env vars + runtime config (packages, repos, scripts) attached to an agent |
| **Vault** | Free-floating bag of env-var overrides. Vault values **win on key collision** when merged with an environment at sprite spawn time |
| **Agent** | A named, re-runnable agent config — model, runtime, skills, MCP servers, optional environment |
| **Conversation** | A single run of an agent inside a Sprites sandbox. Has turns, log events, and a status lifecycle |

## Tenant isolation contract

Every user-facing query is scoped by `user_id`. The pattern is consistent:

```elixir
# CORRECT — tenant-scoped
Agents.get_agent(id, user_id)
Agents.list_agents(user_id, filters)

# WRONG — unsafe, admin-only, prefixed accordingly
Agents._unsafe_get_agent(id)
Agents._unsafe_list_agents()
```

Functions prefixed `_unsafe_` bypass tenant scoping. **Never call them from user-facing code.** They exist for admin views and internal tooling only.

## Envelope encryption

Secrets (environment and vault) are encrypted at rest using a per-tenant DEK (Data Encryption Key) derived from a platform master key:

```elixir
{:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)

# Persist
Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "plaintext"}, dek)

# Read back
%{"TOKEN" => "plaintext"} = Environments.decrypted_env(env, dek)
```

- `dek` is a binary; `upsert_secret` accepts **string-keyed** maps (`%{"key" => ...}`).
- `decrypted_env/2` returns a plain `%{"KEY" => "value"}` map (not a tagged tuple).
- The master key lives in `MASTER_SECRETS_KEY` env var. See `.env.example`.

## Substitution engine

`Fountain.Substitution.apply(value, vars)` substitutes `${VAR}` references:

- `${VAR}` → value from `vars` map
- `$$` → literal `$`
- Returns `{:ok, result}` or `{:error, {:missing_vars, sorted_list}}`
- Recursively walks maps and lists; collects **all** missing vars, not just the first

## LiveView auth hooks

`FountainWeb.Live.Hooks` provides three `on_mount` guards:

| Hook | Unauthenticated | Authenticated but ineligible |
|---|---|---|
| `require_authenticated_user` | `redirect` to `/auth/login` | — |
| `require_active_subscription` | `redirect` to `/auth/login` | `push_navigate` to `/billing` |
| `require_admin` | `redirect` to `/auth/login` | `push_navigate` to `/dashboard` |

The distinction matters in tests: `{:redirect, _}` vs `{:live_redirect, _}`.

## Rate limiter

`FountainWeb.Plugs.RateLimit` — ETS-backed, keyed by IP in prod. In tests:

```elixir
# config/test.exs
config :fountain, :rate_limit_test_isolation, true
```

This switches the key to `{bucket, self()}` so async ExUnit tests don't share counters. Leave this enabled in test config.

## Ueberauth test mode

The `UeberAuthController` skips `plug Ueberauth` when `ueberauth_test_mode: true` (set in `config/test.exs`). This prevents the OAuth plug from overwriting manually-set `conn.assigns` in tests. Don't remove this flag.

## Audit logging

`Fountain.Audit.record/1` is best-effort — it rescues exceptions and returns `{:error, :exception}` rather than raising. Use `record!/1` only where a failure should propagate. Never wrap `record/1` in a way that makes it blocking for the user.

## CI pipeline

`.github/workflows/ci.yml` runs on every push to `main` and all PRs:

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix credo`
4. `mix ecto.create && mix ecto.migrate`
5. `mix test`

Run `mix precommit` locally before pushing — it's the same sequence.

## Test patterns

### Database tests

```elixir
use Fountain.DataCase, async: true   # SQL Sandbox, isolated per-test
```

Pool size is `20` to handle concurrent async modules. Don't lower it.

### Factory helpers

All helpers live in `test/support/factory.ex` and are imported by `DataCase`:

```elixir
user = insert_verified_user()
agent = insert_agent(user_id: user.id)
env   = insert_env(user_id: user.id)
vault = insert_vault(user_id: user.id)

# Factories accept keyword lists or atom/string-keyed maps
# and always persist through the real changeset pipeline
```

`*_attrs/1` helpers return **string-keyed** maps (e.g. `%{"name" => "..."}`) — match with `attrs["name"]`, not `attrs.name`.

### Non-DB tests

```elixir
use ExUnit.Case, async: true         # e.g. Substitution, pure logic
use ExUnitProperties                 # StreamData property tests (installed)
```

### Mocking

Mimic is available. Prefer integration tests through real changesets over heavy mocking.

## Things NOT to do

- **Don't call `_unsafe_*` from user-facing code.** These skip tenant scoping.
- **Don't lower the test pool size below 20.** Pool exhaustion causes flaky timeouts.
- **Don't remove `:ueberauth_test_mode` or `:rate_limit_test_isolation` from `config/test.exs`.** They're correctness guards, not performance flags.
- **Don't push directly to `main`.** All changes go through PRs; the CI gate must pass.
- **Don't add `async: false` to tests unless the test genuinely requires it** (e.g. global ETS state). The SQL Sandbox handles DB isolation.

## Adding a new context

1. Create `apps/fountain/lib/fountain/<context>.ex` with tenant-scoped functions.
2. Add a test at `apps/fountain/test/fountain/<context>_test.exs` with `use Fountain.DataCase, async: true`.
3. Use `_unsafe_` prefix for any admin/internal functions that bypass tenant scoping.
4. If the context handles secrets, use `Fountain.Crypto.load_tenant_key/1` + the pattern above.

## Environment variables

See `.env.example` for the full list. Key ones for local dev:

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection (defaults to `localhost:5432/fountain_dev`) |
| `MASTER_SECRETS_KEY` | Platform master key for envelope encryption |
| `SPRITES_TOKEN` | Token for the Sprites sandbox platform |
| `GITHUB_OAUTH_CLIENT_ID/SECRET` | GitHub OAuth app |
| `STRIPE_*` | Billing integration |
| `RESEND_API_KEY` | Transactional email |

## Decisions

Architecturally significant choices live in `decisions/NNNN-<title>.md`. When a decision is contentious or needs to constrain future work, write an ADR. Use `decisions/0001-template.md` as the template.
