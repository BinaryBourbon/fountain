---
type: ADR
title: "The repo moves to the managoat organization, and every coordinate that names its owner moves with it"
description: "BinaryBourbon/fountain — a personal user account — transfers to managoat/fountain. The repo name and the project name stay Fountain (0034). The owner-scoped coordinates move in the same window because the transfer forces them: ghcr.io/managoat/fountain and ghcr.io/managoat/fountain-manifests, github.com/managoat/fountain/cli and the Buzz provider module beside it, managoat/homebrew-tap. The registry names that carry no owner (npm @agentshit, PyPI fountain-agent-sdk, hex fountain_sdk) are decided here and moved after, each in its own PR. Not built: the transfer has not happened, and nothing in this file is in effect yet."
tags: [infra, open-source, release, deploy]
status: stable
adr: "0048"
adr_status: "Accepted"
date: 2026-09-10
generated: { by: human:jhgaylor, at: 2026-09-10T05:44:52-04:00 }
stale_after: 2026-10-10
---

# 0048 — The repo moves to the managoat organization, and every coordinate that names its owner moves with it

**Status:** Accepted, and **nothing described here is built**. The repo is
still `BinaryBourbon/fountain`; every path, image and module in the "after"
column below is a target, not a current fact. The PR that performs the
transfer and lands the path sweep removes this caveat, sets `verified`, and
drops `stale_after`.

## Context

Everything else has already moved. The hosted product presents as Managoat on
`managoat.com` (#1177, 0034). Nine component libraries graduated to
`managoat/managoat_*` on hex (0037, #1345). The demo suite, `goatherd`,
`airlock`, `manasprites`, `managoat_examples`, the three `fountain-template-*`
starters and `review-loop` are all in the org; `scripts/graduate-library.sh`
already rewrites a graduating library's `@source_url` to
`https://github.com/managoat/<app>` (line 147).

The server repo is the last piece, and it sits under `BinaryBourbon` — a
GitHub **user** account, not an organization. That has three costs:

- **No org primitives.** A user repo cannot carry org-level secrets, teams,
  org rulesets or a second admin. `Main Protection` is a repo ruleset whose
  bypass is one person, and the five repository secrets
  (`FLUX_WEBHOOK_URL`, `HEX_API_KEY`, `HOMEBREW_TAP_TOKEN`,
  `RELEASE_BUMP_TOKEN`, `RENDER_DEPLOY_HOOK_URL`) hang off an account that
  also holds 19 unrelated repositories.
- **Every published coordinate says `binarybourbon`.** The container image,
  the Flux manifest artifact, both Go module paths, the Homebrew tap, the four
  SDK manifests' repository URLs, and 286 references across 126 files in this
  tree. A reader who arrives from `managoat.com` or from
  `managoat/managoat_acp` finds a personal account.
- **0034's split reads wrong from outside.** 0034 decided the names split by
  edition: *Fountain* is the AGPL server, CLI and SDK; *Managoat* is one
  hosted instance; the project is not renamed. That split survives this move —
  the org is where the engineering lives (it already holds nine Fountain
  libraries), the repo name is what the project is called. What it does not
  survive is a personal account being the project's home while the libraries
  extracted *out of* that project live in an org.

The move itself is cheap: GitHub redirects git (clone, fetch, push), the web
UI and the REST API permanently after a transfer, so clones, the ~60 live
worktrees, and every `BinaryBourbon/fountain#1345` reference in commit prose
and in `decisions/` keep resolving. Issues (151 open), pull requests, stars,
forks, webhooks, collaborators and the ruleset come along.

What does not come along is anything that names the owner in a registry, a
module path or a publisher's trust configuration. That is the whole content of
this decision.

## Decision

### 1. `BinaryBourbon/fountain` transfers to `managoat/fountain`

The repo keeps its name. The project keeps its name (0034). `managoat/managoat`
and a Fountain-to-Managoat product rename are **not** this decision and are
rejected below.

### 2. Every coordinate we publish is owner-`managoat`, and its final name is fixed now

Two classes, because they behave differently on the day of the transfer.

**Forced by the transfer** — a package namespace belongs to its owner, and a
repo's `GITHUB_TOKEN` can only write packages in its own owner's namespace.
The moment the repo is under `managoat`, a push to `ghcr.io/binarybourbon/*`
fails with a 403. These move in the same window as the transfer:

| What | Before | After |
|---|---|---|
| Server image | `ghcr.io/binarybourbon/fountain` | `ghcr.io/managoat/fountain` |
| Flux manifest artifact | `ghcr.io/binarybourbon/fountain-manifests` | `ghcr.io/managoat/fountain-manifests` |
| CLI module | `github.com/BinaryBourbon/fountain/cli` | `github.com/managoat/fountain/cli` |
| Buzz provider module | `github.com/BinaryBourbon/fountain/apps/fountain_buzz/cli` | `github.com/managoat/fountain/apps/fountain_buzz/cli` |
| Homebrew tap | `BinaryBourbon/homebrew-tap`, `brew install BinaryBourbon/tap/fountain` | `managoat/homebrew-tap`, `brew install managoat/tap/fountain` |
| Repository URLs in the four SDK manifests | `github.com/BinaryBourbon/fountain` | `github.com/managoat/fountain` |

The image literal lives in `build.yml:35` (`IMAGE`) and the artifact in
`publish-manifests.yml:142` (`MANIFESTS`); neither is derived from
`github.repository`, which is why the first build after the transfer fails
loudly instead of publishing somewhere nobody watches. The published pins are
`docker-compose.yml:39`, `deploy/k8s/deployment.yaml:43`,
`deploy/k8s/kustomization.yaml:29`, `render.yaml:41` and `fly.toml:37`, and
`apps/fountain/test/fountain/release_pin_test.exs:16-19` asserts three of them
by regex — that test is the gate proving the sweep was complete, so it moves
with them rather than being relaxed.

The Go rename is two `go.mod` files plus the cross-module `require` and
`replace` (`apps/fountain_buzz/cli/go.mod:17,22,53`) and the one import
(`apps/fountain_buzz/cli/internal/backend/fountain.go:7`). We rename rather
than keep the old path declared, because the module path is also what
`docs/cli.md` tells a reader to `go install`, and a module path naming an
account that no longer hosts the code is worse than a break we document. The
module proxy keeps serving the old path's existing versions, so a pinned build
keeps building.

**Not forced by the transfer** — these registry names carry no owner, so
nothing breaks on the day. The direction is decided here; each moves in its
own PR, on its own schedule, with both names published during a deprecation
window:

| What | Now | Target |
|---|---|---|
| TypeScript SDK | `@agentshit/fountain-sdk` (npm) | `@managoat/fountain-sdk` |
| Python SDK | `fountain-agent-sdk` (PyPI) | a `managoat`-prefixed name |
| Elixir SDK | `fountain_sdk` (hex) | unchanged unless it collides; hex has no scopes |

An SDK package rename breaks every consumer's `import` — the three template
repos, `managoat/demos`, `fountain-conversations`, `fountain-team`, Workbench,
`salon` — so it is deliberately not coupled to a repository transfer that
breaks none of them.

### 3. No new `binarybourbon` or `agentshit` coordinate, starting now

Any work merged from this point writes the target coordinate, not the current
one. The 48 `@agentshit/fountain-sdk` references in `docs/`, `README.md` and
`CHANGELOG.md` stay until that rename lands (rewriting them before the package
exists would document something unpublishable), but nothing new joins them.

### 4. The old GHCR packages are frozen, not deleted

`ghcr.io/binarybourbon/fountain` and `-manifests` stay public and readable
after the cutover. Any cluster, compose file or `render.yaml` pinned to an old
tag or digest keeps pulling. We stop writing to them; we do not delete them,
and we do not delete the old repo name's redirect by creating anything at
`BinaryBourbon/fountain`.

## Cutover order

The one sequence that can break production. Steps 2 through 5 are a single
merge freeze: between the transfer and the home-cloud change, `main` must not
merge anything, because a build in that gap either fails (before the path
sweep) or publishes to a path Flux is not watching (after it).

0. **Prepare, before anything moves.** This ADR merged. The path-sweep PR
   reviewed and ready but unmerged. The home-cloud PR (OCIRepository `url`,
   `platform/fountain-site`, the Flux webhook receiver) ready but unmerged.
   Record prod's currently running image digest, and confirm `deploy/k8s`'s pin
   is a released tag, so nothing *needs* to deploy during the window.
1. **Freeze `main`.**
2. **Transfer** `BinaryBourbon/fountain` to `managoat`, and
   `BinaryBourbon/homebrew-tap` to `managoat/homebrew-tap`.
3. **Verify what survived, before merging anything.** The five repository
   secrets, the `github-pages` and `pypi` environments, the `Main Protection`
   ruleset and its bypass actor, the required check names (`CI required`),
   Actions being enabled at all, and Dependabot. Recreate whatever did not
   transfer. GitHub's transfer documentation does not promise secrets, so treat
   every one of them as absent until seen.
4. **Merge the path sweep.** The first build publishes
   `ghcr.io/managoat/fountain:sha-<sha>` and the artifact at the new path. Make
   both new packages public and link them to the repo, or a self-hoster's pull
   and Flux's fetch both 401.
5. **Merge the home-cloud PR** and confirm Flux reconciles the new artifact and
   the pod pulls the new digest. Until this lands, prod runs the last old
   digest: safe, and not a deploy path.
6. **Re-point what lives outside both repos.** PyPI trusted publishing names
   the owner, the repo and the workflow filename
   (`python-sdk-publish.yml:5-6`) — update it or the next publish fails, and a
   failed publish is invisible to every gate here. npm provenance verifies
   `package.json`'s repository URL (`sdk-publish.yml:131`). Hex package links.
   The OIDC allow-claim in `managoat/review-loop-action`. The `--repo` default
   in `scripts/ci/require-checks.py:43`.
7. **Unfreeze**, then sweep the prose: 286 references in 126 files, the runtime
   strings users see (`api_spec.ex`, `llms_controller.ex`, `marketing_html.ex`,
   `priv/help/*.md`, `priv/external_skills/fountain/SKILL.md`), `CLAUDE.md`'s
   `gh api /repos/...` recipes, and `scripts/graduate-library.sh`'s commit
   prose.

## Consequences

- **Three things break, and we accept them.**
  `go install github.com/BinaryBourbon/fountain/cli/cmd/fountain@latest` stops
  working once `go.mod` declares the new path (the redirect resolves; Go then
  refuses the mismatched declaration). `binarybourbon.github.io/fountain/*`
  stops serving, because GitHub Pages does not follow a transfer redirect —
  and that is the tombstone whose only job is redirecting retired doc URLs
  (#1011); it gets rebuilt under the org or the old doc URLs die. Published
  self-host instructions pin the old image path, which keeps working but drifts
  from the docs until a reader upgrades.
- **A merge freeze of an hour or two**, during which no deploy can ship.
- **`release_pin_test.exs` and the CLI/SDK tests are the completeness gate.**
  Several tests assert these strings
  (`apps/fountain/test/fountain/{release_pin,team/mcp,conversations/conversation_server}_test.exs`,
  `apps/fountain/test/fountain_web/live/environments_form_live_test.exs`,
  `sdk/typescript/test/resources.test.ts`, the `cli/` suites). A sweep that
  misses a file fails CI rather than shipping a dead URL.
- **Bus factor improves** in the one place it was worst: the repo can have a
  second admin without handing over a personal account.
- **This ADR amends 0034, it does not contradict it.** The project is still
  called Fountain; its GitHub home is now the organization that already
  publishes its libraries.

## Alternatives considered

- **`managoat/managoat`, renaming the product into the repo** — implies
  renaming Fountain itself: the `:fountain` OTP app, the `fountain` binary,
  every `FOUNTAIN_*` env var, 100+ doc pages, three `fountain-template-*`
  repos. 0034 decided the project is not renamed, and nothing here changes
  that argument.
- **Rename the `BinaryBourbon` user account to `managoat`** — impossible (the
  org holds the login) and wrong anyway: it would drag 19 unrelated
  repositories and the account's own identity along.
- **Leave the repo and move only the packages** — GHCR writes are owner-scoped,
  so publishing to `ghcr.io/managoat/*` from a `BinaryBourbon` repo needs a
  cross-account PAT in CI. More credential, same fallout, later.
- **Fresh repo in the org plus a push** — loses 151 open issues, the PR
  history, the stars and every cross-reference in `decisions/`.
- **Do it gradually, one coordinate at a time** — the forced set cannot be
  gradual: the transfer invalidates every GHCR write at once. Gradual is
  exactly what the second table is for.

## Related

- 0034 — the project/product name split this move is tested against.
- 0037 / #1345 — the library graduations that put nine Fountain repos in the
  org first, and `scripts/graduate-library.sh`, which already writes
  `managoat/` URLs.
- 0032 / #304 — the manifest artifact and the Flux consumer whose URL is the
  riskiest line in the cutover.
- #1008 / #1011 — the Pages retirement and the tombstone that a transfer
  silently takes offline.
