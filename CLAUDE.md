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
    lib/fountain_web/      elixirc_paths/test_paths. Licence boundary: ee/ is
    test/                  Elastic 2.0, the server is AGPL-3.0 (0010, 0027).
                           Account email + Mailer are core (#475/#476).
  config/
    config.exs             shared config
    dev.exs                dev overrides
    test.exs               test overrides (pool_size: 20, test-mode flags)
    prod.exs               prod overrides
  .github/workflows/ci.yml CI pipeline
  decisions/               ADRs (Architecture Decision Records)
  docs/                    the public manual, served at /docs (nav.yml is the nav)
```

## Architecture: the four primitives

| Primitive | Purpose |
|---|---|
| **Environment** | Baseline set of encrypted env vars + runtime config (packages, repos, scripts) attached to an agent. A conversation may name a different one at launch (`environment_id`; scoped by `agent.allowed_environment_ids`) — the agent's is the default, not the only choice |
| **Vault** | Free-floating bag of env-var overrides. Vault values **win on key collision** when merged with an environment at sprite spawn time |
| **Agent** | A named, re-runnable agent config — model, runtime, skills, MCP servers, optional environment |
| **Conversation** | A single run of an agent inside a Sprites sandbox. Has turns, log events, and a status lifecycle |

## Plans and entitlements

`Fountain.Plans` is the catalog: three public tiers (`solo` / `team` /
`scale`) plus a closed `legacy` one, differing on **one** axis — how many
sandboxes a tenant may run at once. Everything else the product does is on
every plan.

| | trial | solo | team | scale | legacy |
|---|---|---|---|---|---|
| concurrent sandboxes | 2 | 2 | 5 | 10 | 5 |
| included turn hours | 40 | 40 | 100 | 200 | 100 |
| teammate contacts | 0 | 1 | 3 | 10 | 3 |
| price | free | $29 | $79 | $199 | $29 (closed) |

Five rules that are easy to get wrong:

- **A trialing account gets `trial`'s numbers, not its tier's.**
  `Plans.effective/1` is what applies today; `Plans.resolve/1` is the tier the
  subscription names and what it converts into. Every entitlement reader
  (`concurrent_sandboxes/1`, `included_turn_hours/1`, `team_contacts/1`) routes
  through `effective/1` **when handed a `%User{}`** — hand it a bare slug and
  it cannot know the status, which is how `turn_hour_allowance/2` first got it
  wrong. The trial now *ties* Solo on concurrency and hours — the guardrail
  is that it is never larger than a plan somebody pays for, and contacts are
  the only axis still separating the two. Only applies when billing is on:
  `subscription_status` defaults to `"trialing"`, so without that guard every
  self-hosted account would be capped at two sandboxes. In tests, `insert_verified_user/1` is trialing —
  `insert_active_user/1` is the one that gets the plan's numbers.

- **The plan is not the cap.** `Quotas.sandbox_limit/1` returns
  `users.sandbox_limit_override` when it is set and the plan's number
  otherwise. Anything that displays a cap must show the enforced one
  (`Quotas.sandbox_limit_for/1` for an already-loaded user), never
  `plan.concurrent_sandboxes`. Note the Postgres column is still
  `max_concurrent_sandboxes` — the Elixir field is mapped with Ecto's
  `:source`, deliberately, so a rolling deploy does not break (see the
  migration).
- **Only the webhook writes `users.plan`.** `Billing.change_plan/3` asks
  Stripe to reprice the subscription and writes nothing locally; the
  `customer.subscription.updated` that comes back is what stamps the slug. So
  the entitlement follows what Stripe charges, not what we asked for. An
  unrecognised price leaves the stored plan alone rather than nulling it.
- **Teammate contacts are billed per unit, not included in a tier.**
  `Billing.sync_contact_addon/1` *sets* an add-on subscription item's quantity
  from the contact rows (never increments), best-effort, after the row
  commits. The plan's `team_contacts` number is an abuse ceiling on top, not
  an allowance. Two levers comp one: `comp_account/1` makes everything free,
  `users.comped_contacts` takes N off the billed quantity for a tenant who
  still pays for their tier.

- **A turn hour is not a sandbox hour, and nothing enforces either.**
  `included_turn_hours` is 20 per concurrent slot, measured against
  `SandboxUsage`'s `busy_seconds` (a prompt in flight) on platform-paid
  providers only — an idle sandbox and a self-hosted runner spend none of it.
  `Billing.turn_hour_allowance/2` is the one shape every surface renders, so
  they cannot disagree. **No gate reads it** (#1016 steps 4 and 5 are unbuilt);
  do not add one without deciding the overage shape first.

- **Usage is measured over the invoiced period, or says it is not.**
  `Billing.billing_period/2` returns `%{start, end, source}` — `:subscription`
  from `users.current_period_start`/`_end`, `:calendar_month` when there is no
  such period (comped, self-hosted, or no webhook yet). The fallback is never
  silent: if you add a surface that shows a usage number, show the source too.
  `Fountain.Release.backfill_billing_periods/1` fills the column from Stripe
  for accounts that predate it.

Price ids come from config (`STRIPE_PRICE_ID_SOLO` and friends), the display
cents from the catalog. `mix fountain.verify_plans` is the only thing that
stops those two drifting — run it after any price change.
**decisions/0026-plans-and-entitlements.md** owns all of this.

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

## The web UI is a console

Fountain's own browser UI is an **operator console**: the dashboard, agents,
environments, vaults, audit, API keys, account and admin. It is deliberately
not an interactive application.

Watching an agent work and messaging a teammate are separate single-page apps
on `/api`, on their own origins with their own OAuth clients:

| App | Repo | Replaced |
|---|---|---|
| Conversations | [jhgaylor/fountain-conversations](https://github.com/jhgaylor/fountain-conversations) | `/conversations`, `/conversations/new`, `/conversations/:id`, `/conversations/:id/logs` |
| Team | [jhgaylor/fountain-team](https://github.com/jhgaylor/fountain-team) | `/team`, `/team/:agent_id` |

`Fountain.Apps` is the only place that knows where they live
(`CONVERSATIONS_APP_URL` / `TEAM_APP_URL`, defaulting to the hosted builds;
`""` means this deployment has none). Anything that links a human to a
transcript — the console, an email, a forwarded support report, `/api/catalog`
— reads it from there. The old paths redirect (`FountainWeb.MovedController`)
rather than 404, and `/onboarding*` goes to the dashboard, whose checklist
replaced the wizard.

**Building a conversation-facing feature? It goes in the app, not here.** The
server's job is to serve it: `?blocks=true` on `/events` and the streams means
no client re-parses a runtime dialect.

## LiveView auth hooks

`FountainWeb.Live.Hooks` provides these `on_mount` guards:

| Hook | Unauthenticated | Authenticated but ineligible |
|---|---|---|
| `require_authenticated_user` | `redirect` to `/auth/login` | — |
| `require_admin` | `redirect` to `/auth/login` | `push_navigate` to `/dashboard` |
| `assign_subscription_state` | — | never halts; assigns `@subscription_active` |

The distinction matters in tests: plain `redirect` yields `{:redirect, _}` (the
login redirect), while `push_navigate` yields `{:live_redirect, _}` (the
non-admin case in `require_admin`).

There is no router-level subscription gate. It guarded exactly one page,
`/conversations/new`, which moved out to the app. The gate that protects spend
is `Billing.assert_active!/1` **in the context** (ADR 0006), so every door gets
it — see `ee/test/fountain/billing_gate_test.exs`.

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
10. The test suite, as six partitions in six parallel jobs (`scripts/test-partition.sh`), plus a `coverage` job that merges their exports with `scripts/coverage-gate.exs` and enforces the 85% threshold
11. Release boot check — builds a prod release, probes `/health` and `/health/ready`, runs a release task beside the live server
12. `mix openapi.spec.json` + `jq empty` (OpenAPI spec validates)

On `main` the run usually short-circuits: the `already-tested` job compares
the pushed commit's tree with the head of the merged PR and, when they are
identical and that head has a successful `pull_request` CI run, every other
job is skipped and `build.yml` starts straight away (the run still concludes
`success`, which is its gate). A rebased squash-merge is that case; anything
else — a tree that differs, no PR, no green run — gets the full run.

### Coverage

Coverage uses Elixir's built-in cover, not ExCoveralls — ExCoveralls cannot
merge results across machines, and since #620 the suite runs as six
partitions on six of them (three until #894). Settings live in `coverage.exs` at the repo root
(read by both mix.exs files): `summary: [threshold: 85]` and `:ignore_modules`,
which replaced `coveralls.json`'s `minimum_coverage` and `skip_files`.

`:ignore_modules` matches **module names**, not source paths — a bare atom for
one module, a regex against `inspect(module)` for what used to be a
directory entry. Locally, `mix test --cover` reports and gates in one step.

CI enforces the threshold with `scripts/coverage-gate.exs`, not
`mix test.coverage`: ~90% of that task's time is rendering an HTML report the
job never opens. The script reads the same `coverage.exs` and was verified to
produce the identical total (85.46% on the same six exports). Run
`mix test.coverage` locally when you want the per-module table or the HTML —
and re-verify the two agree when bumping Elixir, since the script depends on
`:cover` semantics the pin currently freezes.

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
- **Don't start fire-and-forget work with `Task.async`.** It *links* to the
  caller and nothing awaits it, so a transient failure in a write nobody wants
  the result of takes the request process down — and under the SQL Sandbox that
  process is the test, which is how a stamp on `last_used_at` failed a
  scheduling test that had already passed (#1040). Use
  `Task.Supervisor.start_child(Fountain.TaskSupervisor, fun)`: unlinked,
  supervised, and a crash is logged. `DataCase` waits for the tasks a test
  started before stopping the sandbox owner, so the write lands rather than
  having its connection pulled away. `Task.async` is right where the caller
  keeps the ref and handles the reply (`Analytics.Sink`).
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

## Docs (`docs/`)

`docs/` is the public manual, published at `/docs` and **nowhere else** — the
markdown is embedded at compile time by `Fountain.Docs`. It used to be built as
a MkDocs Material site and deployed to GitHub Pages as well; that copy was
retired in #1008, so there is no `mkdocs.yml`, no `docs.yml` workflow and no
`mkdocs build` step to keep green. A page reaches a reader through `/docs` or
not at all.

The one thing left on GitHub Pages is a **tombstone** (#1011): one redirect per
old URL into `/docs`, built by `scripts/build-pages-tombstone.py` from the nav
and published by hand from `.github/workflows/pages-tombstone.yml`. It is
`workflow_dispatch` only and reads no page content. **Do not turn it into a
docs publishing path**, and do not treat a docs edit as needing a re-run —
the redirects only go stale if a page's *slug* changes.

Guardrails that trip people who only edit markdown:

- **The nav lives only in `docs/nav.yml`.** `Fountain.Docs` parses that file's
  `nav:` block at compile time, so adding, renaming or moving a page is a
  one-file change. It used to be mirrored in `@nav` in
  `apps/fountain/lib/fountain/docs.ex` with a drift test, which is exactly how
  docs-only PRs kept going red in *partition 3* of CI, looking unrelated to
  the docs. Keep to the two line shapes the parser reads — `  - Title: x.md`,
  and a `  - Section:` header with six-space-indented children — because a
  line it cannot read raises at compile time rather than being skipped.
  **Sections are one level deep.** The in-app sidebar renders exactly a section
  and its pages, so a sub-section (or a page indented past its siblings) raises
  too. Flatten it into a sibling section — `Catalog` is what that looks like,
  with the three hub pages sitting among their own entries — or make it
  headings on a hub page.
- **A page not in the nav is published nowhere.** `docs_test.exs` walks
  `docs/**/*.md` both ways: every page the nav names exists, and every page on
  disk is named. There is no allowlist. If a markdown file should not be read
  at `/docs`, it belongs somewhere else — `runbooks/`, `decisions/` and
  `superpowers/` are all deliberately unpublished. MkDocs used to build an
  unlisted page anyway, so four of them accumulated under `docs/superpowers/`
  before this check existed.
- **Anything `Fountain.Docs` reads at compile time must be `COPY`d into the
  Docker build stage.** The release image contains no `docs/`, only strings
  baked out of it, so a file outside the `COPY` list does not degrade to a
  broken link: `mix release` dies, no image is built, CI stays green and the
  deploy silently never happens (#884). `docs_test.exs` asserts the module's
  `@external_resource` list against the Dockerfile, so adding a new
  compile-time read fails there first.
- **Links and anchors are checked by the suite, not by a site build.** Every
  internal `/docs` link must resolve to a page, and every `#anchor` to a
  heading on that page. `mkdocs build --strict` used to carry the link half of
  this on `main` only; `docs_test.exs` carries both, on every PR, and it is the
  stricter of the two — MkDocs never checked anchors. Run
  `mix test apps/fountain/test/fountain/docs_test.exs`.
- **`python3 scripts/docs-style.py`** enforces the style sheet
  (`docs-redesign/06-voice-and-style.md`): no em dashes, no colon-introduced
  lists, no "simply"/"obviously"/"coming soon". It skips the backlog in
  `scripts/docs-style-allow.txt`, so a file **not** on that list is checked and
  every new page is covered by default. Cleaning a page means deleting its
  line; the list only shrinks (#911).
- **`vale lint docs` enforces ASD-STE100 Simplified Technical English.** Every
  published page is written in it. The standard is
  `docs-redesign/08-simplified-technical-english.md`; config is
  `.vale-ste.yml`; the backlog is `.valeignore` and is **empty**. The linter is
  [`stuffbucket/vale`](https://github.com/stuffbucket/vale) — MIT, pure Go.
  Install it with `brew install stuffbucket/tap/vale`. CI uses the pinned
  `v0.15.0` release binary, checksum-verified, **not** `go install`: the jobs
  pin Go from `cli/go.mod` with `GOTOOLCHAIN=local` and cannot fetch the newer
  toolchain the module wants. The gate is six rules: sentence length (20
  procedural / 25 descriptive), contractions, the passive voice, phrasal verbs,
  one instruction per sentence, and the -ing form. `STE.Vocabulary` advises and
  does not gate, because its wordset was built for aircraft maintenance. Read
  the standard before you fight the linter — it lists the three traps (joined
  table cells, a code span opening a sentence, `anything` matching the -ing
  rule) and where a suppression comment is legitimate.
- **`docs/cli.md` is diffed against the CLI.** `cli/internal/cmd/docs_test.go`
  fails if a command exists that the page does not mention, or the page
  mentions one that does not exist. Add a CLI command → add it to `docs/cli.md`
  in a fenced `bash` block.

The dialect the renderer understands is small (snippet includes, admonitions,
relative `.md` links) and is inherited from the MkDocs site these pages used to
be; check a page at `/docs` if it uses anything fancier. Nothing else renders
them, so `/docs` is the answer, not a second opinion.

## Decisions

Architecturally significant choices live in `decisions/NNNN-<title>.md`. When a decision is contentious or needs to constrain future work, write an ADR. Use `decisions/0001-template.md` as the template.

`decisions/` is an [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) bundle. Start at `decisions/index.md`, which lists every ADR with its status, whether it has been verified against the code, and when its status block goes stale. Each ADR's frontmatter carries `adr_status`, `verified` and `stale_after`; the template explains the fields. CI runs `okf validate decisions` and regenerates the index (`scripts/decisions-index.sh`), so a new ADR needs frontmatter and an index refresh in the same PR; run both locally before pushing. `okf backlinks decisions <id>` lists the ADRs that depend on one before you amend it. The `okf` CLI is a single Go binary from [okfcli/okf](https://github.com/okfcli/okf): `brew install okfcli/okf/okf`, or `go install github.com/okfcli/okf/cmd/okf@latest`, or the pinned linux tarball the workflow downloads (`.github/workflows/decisions.yml`). Every command prints JSON; `okf schema` describes them all.

**ADRs and docstrings must not describe unbuilt behavior as existing.** The 2026-07 audit found three mechanisms asserted as implemented (a quota check, metering call sites, a gate backstop) that did not exist — anyone reading the ADRs concluded the system was metered, capped and gated when it was none of those. If a document describes behavior that is not yet in code, say so explicitly (`**Status:** Proposed`, "not yet built"), and remove the caveat in the PR that builds it.
