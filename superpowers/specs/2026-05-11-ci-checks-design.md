# CI Checks Design

**Date:** 2026-05-11
**Status:** Approved
**Scope:** Sub-project 1 of 4 in the Engineering Excellence initiative

## Context

Fountain currently has two GitHub Actions workflows:
- `deploy.yml` — triggers a Render deploy on push to `main`
- `release.yml` — builds and publishes Go CLI binaries on version tags

There is no workflow that runs on pull requests. PRs today have zero automated quality gates. The `mix precommit` alias (compile, format, credo, tests) exists locally but is never enforced by CI.

## Goal

Add a `ci.yml` workflow that runs on every push to `main` and every pull request, enforcing the same quality bar as `mix precommit` — but with per-step visibility and without the mutation step (`deps.unlock --unused`) that is inappropriate in CI.

## Workflow Design

**File:** `.github/workflows/ci.yml`

### Triggers

```yaml
on:
  push:
    branches: [main]
  pull_request:
```

### Infrastructure

Single job `test` on `ubuntu-latest` with a `postgres:16` service container. Credentials use the defaults already hardcoded in `config/test.exs`:
- user: `postgres`
- password: `postgres`
- database: `fountain_test`
- port: `5432`

No repository secrets are required for CI to run.

### Toolchain Pinning

Versions sourced from `.tool-versions`:
- Erlang/OTP: `28`
- Elixir: `1.19.2`

Uses `erlef/setup-beam@v1`.

### Caching Strategy

Two separate caches to avoid stale artifacts across toolchain upgrades:

| Cache | Path | Key |
|-------|------|-----|
| deps | `deps/` | `{os}-mix-{mix.lock hash}` |
| build | `_build/` | `{os}-build-{otp}-{elixir}-{mix.lock hash}` |

Restore keys fall back to prefix matches so partial cache hits are still useful.

### Steps (in order)

1. `actions/checkout@v4`
2. `erlef/setup-beam@v1` — pin OTP + Elixir
3. Restore `deps/` cache
4. Restore `_build/` cache
5. `mix deps.get`
6. `mix compile --warnings-as-errors`
7. `mix format --check-formatted`
8. `mix credo --strict`
9. `mix ecto.create --quiet && mix ecto.migrate --quiet`
10. `mix test`

### Why not `mix precommit`?

The precommit alias includes `deps.unlock --unused`, which mutates the lockfile. In CI this would silently succeed rather than flag a problem. Breaking steps out individually also gives GitHub a per-step status panel in the PR checks UI, making failures easier to triage.

### What is excluded

- **Dialyxir** — too slow without a warmed PLT cache. PLT cache setup adds meaningful complexity (PLT path, invalidation strategy). Deferred to a future iteration once the baseline CI is stable and trusted.

## Acceptance Criteria

- [ ] `ci.yml` exists at `.github/workflows/ci.yml`
- [ ] Workflow runs on push to `main` and on pull requests
- [ ] A PR with a compilation warning fails the check
- [ ] A PR with misformatted code fails the check
- [ ] A PR with a Credo violation fails the check
- [ ] A PR with a failing test fails the check
- [ ] `deps/` and `_build/` are cached between runs
- [ ] No repository secrets are required for the workflow to run

## Out of Scope

- Dialyxir type checking (deferred)
- Test coverage reporting (deferred to Testing sub-project)
- Docs deployment workflow (deferred to Public Docs sub-project)
- Branch protection rules (manual step post-implementation)
