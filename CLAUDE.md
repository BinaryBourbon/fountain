# CLAUDE.md — Contributor Guide

This file is read by Claude Code (and other AI coding tools) at session start. Keep it accurate — stale guidance misleads every downstream dispatch.

## Quick start

```bash
mise install                        # pin Erlang/OTP 28 + Elixir 1.19.2
mix deps.get
mix setup                           # dev DB: create + migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test                            # full suite (~1,850 tests)
mix precommit                       # the core CI checks, locally
```

See [SETUP.md](SETUP.md) for full workstation bootstrap (Postgres, OAuth keys, etc.).

## Repo layout

```
fountain/                  umbrella root
  apps/
    fountain/              core business logic (Elixir OTP app)
      lib/fountain/        contexts: Accounts, Agents, Environments, Vaults,
      |                              Conversations, Crypto, Audit, Substitution
      lib/fountain_web/    Phoenix: controllers, LiveView, plugs, router
      test/fountain/       context unit tests (async: true, DataCase)
      test/fountain_web/   controller/LiveView integration tests
      test/support/        DataCase, ConnCase, factory.ex
  ee/                      billing + growth email (welcome/trial/payment),
    lib/fountain/          compiled into the same :fountain app via
    lib/fountain_web/      elixirc_paths/test_paths. Possible-license boundary
    test/                  (MIT today) — decisions/0010 + its addendum.
                           Account email + Mailer are core (#475/#476).
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
Conversations._unsafe_get_sandbox(id)
```

Functions prefixed `_unsafe_` bypass tenant scoping. **Never call one as the
first fetch in a user-facing request** — ownership must already be
established on that request before an `_unsafe_` call is legitimate.

The prefix goes on *every* unscoped function, including ones whose callers
happen to check ownership first — the reader of a call site should not have to
go and find out. The legitimate callers are:

- an admin surface behind `require_admin`;
- a system-level sweep like the rehydrator or `SandboxReaper`;
- a GenServer that has already established ownership;
- **a user-facing call site directly after a tenant-scoped parent fetch** —
  the dominant pattern since #383:

  ```elixir
  # CORRECT — ownership established by the scoped get_vault above
  vault = Vaults.get_vault(vault_id, user.id)
  secrets = Vaults._unsafe_list_secrets(vault)
  ```

  The scoped fetch and the `_unsafe_` child call must be adjacent and in the
  same function, with a comment saying which fetch established ownership.

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
| `require_active_subscription` | `redirect` to `/auth/login` (via `require_authenticated_user`, which must run first) | `redirect` to `/account/billing` |
| `require_admin` | `redirect` to `/auth/login` | `push_navigate` to `/dashboard` |

The distinction matters in tests: plain `redirect` yields `{:redirect, _}` (login and billing redirects), while `push_navigate` yields `{:live_redirect, _}` (the non-admin case in `require_admin`).

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

**Mutations audit in the context, not the caller.** A function that changes
tenant-owned state records its own event, so the UI, the API, background
workers and any future surface are covered by construction rather than by each
caller remembering. This is the rule the #540 campaign established after
finding seven contexts with no audit calls at all and coverage that depended on
which door a request came through.

```elixir
# CORRECT — the context records; the caller supplies only attribution
def create_agent(attrs, opts \\ []) do
  %Agent{} |> Agent.changeset(attrs) |> Repo.insert() |> audited("agent.created", opts)
end

# at the call site
Agents.create_agent(attrs, Audited.attribution(conn))     # or (socket)
Agents.create_agent(attrs, actor: "system:my_worker")     # background caller
```

`FountainWeb.Audited.attribution/2` returns the `:actor` / `:request_ip` pair
for a `%Plug.Conn{}` or a LiveView socket. Pass an override where the
connection cannot reveal the actor — at registration and at
`POST /api/auth/token` there is no session yet, so derivation would report
`"system"` for a plainly-human action.

Three rules that are easy to get wrong:

- **Never audit inside a transaction.** `record/1` is best-effort *by rescuing*,
  and that does not survive a transaction — a failed insert aborts the enclosing
  one, so a lost audit row would take the mutation with it. Record outside.
- **Never record values.** Update events name the fields that changed
  (`Audit.changed_fields/1`); secret, credential and prompt events record keys,
  sizes and providers. The trail is not a second copy of tenant data.
- **Only record what happened.** A rejected changeset or a no-op sync records
  nothing; a trail that logs attempts as changes is worse than no trail.

`apps/fountain/test/fountain/audit_guardrail_test.exs` enforces this: add a
context mutation and the guardrail fails until it audits, or until you add it
to the documented exclusion list with a reason.

The actor vocabulary is closed: `self` (the context default), `ui`, `api`,
`sprite`, `admin`, `admin:<operator_id>` (account deletion only) and
`system:<worker>`. A bare `"system"` — what `attribution/2` derives when a
request has no principal — is a defect, not a value: the unauthenticated
routes (login, registration, `POST /api/auth/token`, email verification) pass
an explicit actor. **decisions/0013-audit-trail.md** owns all of this, plus
the deliberate exclusions, the two-rows-per-API-mutation choice and the
deletion semantics; read it before adding an actor string or moving a
recording out of a context.

`Fountain.Audit.record!/1` is deliberately test-only — see its docstring. Never
wrap `record/1` in a way that makes it blocking for the user.

## CI pipeline

`.github/workflows/ci.yml` runs on every push to `main` and all PRs:

1. `mix deps.unlock --unused` (fails if `mix.lock` has unused entries)
2. `mix format --check-formatted`
3. `mix compile --warnings-as-errors`
4. `mix credo --strict`
5. `mix hex.audit` (non-blocking — visible in the log, doesn't fail the build)
6. `mix sobelow --config` (security scan)
7. `MIX_ENV=dev mix dialyzer`
8. Go CLI checks: `go test ./...` and `go vet ./...` in `cli/`
9. `mix ecto.create && mix ecto.migrate`
10. The test suite, as three partitions in three parallel jobs (`scripts/test-partition.sh`), plus a `coverage` job that merges their exports with `mix test.coverage` and enforces the 85% threshold
11. Release boot check — builds a prod release, probes `/health` and `/health/ready`, runs a release task beside the live server
12. `mix openapi.spec.json` + `jq empty` (OpenAPI spec validates)

### Coverage

Coverage uses Elixir's built-in cover, not ExCoveralls — ExCoveralls cannot
merge results across machines, and since #620 the suite runs as three
partitions on three of them. Settings live in `coverage.exs` at the repo root
(read by both mix.exs files): `summary: [threshold: 85]` and `:ignore_modules`,
which replaced `coveralls.json`'s `minimum_coverage` and `skip_files`.

`:ignore_modules` matches **module names**, not source paths — a bare atom for
one module, a regex against `inspect(module)` for what used to be a
directory entry. Locally, `mix test --cover` reports and gates in one step.

Run `mix precommit` locally before pushing — it covers the core gate (compile with warnings-as-errors, unused deps, format, `credo --strict`, sobelow, dialyzer, tests). CI additionally runs hex.audit, the Go CLI checks, the release boot check, and OpenAPI validation.

## Test patterns

`mix test` at the umbrella root runs core and `ee/test` together. To run a
single ee file by path, run from `apps/fountain` (`mix test ../../ee/test/...`)
or pass an absolute path — root-relative `ee/...` paths don't resolve.

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

- **Don't reach for `_unsafe_*` without established ownership.** These skip tenant scoping; the legitimate caller shapes (including the scoped-parent-fetch-then-`_unsafe_`-child pattern) are in the tenant isolation section above.
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

`decisions/` is an [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) bundle. Start at `decisions/index.md`, which lists every ADR with its status, whether it has been verified against the code, and when its status block goes stale. Each ADR's frontmatter carries `adr_status`, `verified` and `stale_after`; the template explains the fields. CI runs `okf validate decisions` and regenerates the index (`scripts/decisions-index.sh`), so a new ADR needs frontmatter and an index refresh in the same PR. `okf backlinks decisions <id>` lists the ADRs that depend on one before you amend it.

**ADRs and docstrings must not describe unbuilt behavior as existing.** The 2026-07 audit found three mechanisms asserted as implemented (a quota check, metering call sites, a gate backstop) that did not exist — anyone reading the ADRs concluded the system was metered, capped and gated when it was none of those. If a document describes behavior that is not yet in code, say so explicitly (`**Status:** Proposed`, "not yet built"), and remove the caveat in the PR that builds it.
