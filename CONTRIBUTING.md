# Contributing to Fountain

Start with [`CLAUDE.md`](CLAUDE.md) for architecture, the tenant isolation
contract, test patterns and the things not to do. Architecturally significant
choices are recorded as ADRs in [`decisions/`](decisions/).

## Licensing of contributions

Fountain is not licensed as a single unit. **The license that applies to your
contribution is the license of the directory you are editing**, and each one
carries its own LICENSE file:

| Directory | License |
|---|---|
| `apps/fountain`, `config`, `priv` | GNU AGPL v3.0 or later |
| `ee/` | Elastic License 2.0 |
| `cli/`, `sdk/typescript` | Apache License 2.0 |

**You contribute under the Apache License 2.0, whichever directory you are
editing.** Fountain then distributes your work under the license governing that
directory, from the table above. There is no separate document to sign and no
CLA bot. Opening a pull request is the grant.

You keep the copyright in your work. This is a license, not an assignment, and
Apache-2.0 does not restrict you, so you keep the full right to reuse your own
contribution anywhere else, including in proprietary code of your own.

The asymmetry, stated plainly so nobody is surprised later: Apache-2.0 permits
relicensing, so Fountain's maintainer can distribute your contribution under
the AGPL, under the Elastic License, or under a commercial license sold to a
company whose policy forbids the AGPL. You cannot do the same with anyone
else's contribution. That is the same asymmetry a CLA creates, with less
ceremony, and it exists for one reason: without it, the option to sell a
commercial exception closes permanently the first time an outside pull request
is merged. If that trade is not one you want to make, say so on the pull
request. It is a reasonable thing to object to.

For `cli/` and `sdk/typescript` this changes nothing at all, since inbound and
outbound are both Apache-2.0 there.

## Sign your commits (DCO)

Fountain uses the [Developer Certificate of Origin](https://developercertificate.org/).
It is a one-line assertion that you wrote the patch, or otherwise have the right
to submit it. Your sign-off also records your agreement to the inbound terms
above. Add it with `-s`:

```bash
git commit -s -m "fix(agents): ..."
```

That appends a `Signed-off-by:` trailer using your `user.name` and
`user.email`. Note that `git config format.signOff true` does **not** do this
for `git commit`; use `-s`, or install a `commit-msg` hook.

## Before you push

```bash
mix precommit
```

That runs the core gate locally: compile with warnings as errors, unused deps,
format, `credo --strict`, sobelow, dialyzer and the test suite. Read the
output rather than trusting the exit code, since an alias stage can fail while
the alias still exits 0. Confirm you reached `N tests, 0 failures`.

CI additionally runs `hex.audit`, the Go CLI checks (`go test ./...`,
`go vet ./...` in `cli/`), a release boot check, OpenAPI validation, and the
docs gates. If you touched `docs/`, run the three prose gates too:

```bash
python3 scripts/docs-style.py
vale lint docs
npm ci --prefix scripts/destink && node scripts/destink/destink.mjs
```

The third one looks for AI-writing tells. Its engine is the published
`sentences` package, so the `npm ci` installs it (~5M) and is only needed the
first time. If it reports something that is not prose — a table cell, a CLI
flag, anything inside a code fence — the fix belongs upstream in the
package's `lint/markdown-prose`, not in the page. The rule set, and why each
rule is on or off, is in `scripts/destink/destink.mjs`.

The structural half — every page named in `docs/nav.yml`, every page on disk
named there, and every internal `/docs` link and anchor — is in the test suite,
so `mix precommit` already covers it:

```bash
mix test apps/fountain/test/fountain/docs_test.exs
```

To read a page as it will ship, start the server and open `/docs`. That route
is the only place `docs/` is published.

## Adding an umbrella library app

Fountain's database-free subsystems were extracted as Apache-2.0 libraries
under the `Managoat.*` namespace (decisions/0037, tracker #1334). Each
started as an app in this umbrella, `apps/managoat_<name>`, and graduated to
a `managoat/managoat_<name>` repository once its surface stopped moving; all
nine have (#1345; managoat_runtimes, #1368, by the same recipe), so the
umbrella holds none today. A new one starts the
same way. The model to copy is the last extraction as merged,
`git show 1b848031 -- apps/managoat_substitution` (#1347, the smallest), or
`managoat/managoat_substitution` on GitHub minus what the graduation
template added. A new one needs:

- `apps/managoat_<name>/mix.exs` with the three umbrella path lines
  (`build_path`, `deps_path`, `lockfile`) and deliberately **no**
  `config_path`: `config/runtime.exs` calls Fountain modules, so a library
  pointed at it cannot boot from its own directory. The library's tests must
  pass with no config at all (set what they need in `test/test_helper.exs`
  or per test). Plus `package` metadata with `licenses: ["Apache-2.0"]`, and
  its own `test_coverage` threshold.
- `LICENSE` (Apache-2.0, copy `cli/LICENSE`), `README.md`, `.formatter.exs`,
  `test/test_helper.exs`.
- A line in `apps/fountain/mix.exs`: `{:managoat_<name>, in_umbrella: true}`.
- A `COPY apps/managoat_<name>/mix.exs` line in the Dockerfile's deps layer,
  beside the existing one. Without it `mix deps.get` fails in the image
  build, which CI does not run.
- No reference to `Fountain.*` or `FountainWeb.*`, no
  `Application.get_env(:fountain, …)`, and no `[:fountain, …]` telemetry
  anywhere under its `lib/` or `test/`. The library takes what it needs as
  arguments or reads its own otp_app.
- If the library's `test/test_helper.exs` writes its own config (a test
  host, a stub name), Fountain's `apps/fountain/test/test_helper.exs` must
  set the value Fountain needs for that same key, with a comment. `mix test`
  at the umbrella root runs every app in one VM, so a library helper's
  `put_env` is still in effect when Fountain's suite starts (#1352 lost ten
  runner tests to this). CI never sees it, since the partitions and
  `scripts/test-libraries.sh` are separate VMs; `mix precommit` does.

`apps/fountain/test/fountain/umbrella_layout_test.exs` checks every one of
those and fails the suite on a miss. The root gates already reach the new
app: `mix format` through `subdirectories: ["apps/*"]`, credo through
`apps/*/lib/`, dialyzer and `mix test` because they run at the root. In CI
the library's tests run from `scripts/test-libraries.sh` in one partition
and their coverage export joins the merged gate, so a library with no tests
fails the run rather than passing unmeasured. Add a `[Unreleased]` entry
and update the "Built so far" block in decisions/0037.

## Graduating a library

The reverse of the section above: an `apps/managoat_<name>` app leaves this
umbrella for a repository of its own, `managoat/managoat_<name>` (the same
string as the hex package), from which CI publishes it to hex, and
`apps/fountain` pins the hex release. The recipe is `scripts/graduate-library.sh`
plus `templates/managoat-library/`; #1345 wrote both and proved them on
`managoat_substitution`, then ran them for the other seven.

**When.** A library graduates when it has stopped moving: its public surface
has not changed since extraction, or its last change was a release of its own
rather than a fix that a Fountain PR needed the same day. There is no open
issue that needs a change on both sides of the seam. Until then the umbrella
gives the compile-time boundary at no release cost; after, every cross-seam
change costs two PRs (below).

**Prerequisite, org admin only.** The publish workflow authenticates with
`HEX_API_KEY`, an organization-level secret on `managoat` visible to every
repository, holding a write key from the hex.pm user account that owns every
`managoat_*` package. There is no hex organization and hex has no trusted
publishing; that key, used only by CI, is the mechanism. Listing org secrets
needs a scope your `gh` token may not have, so the check is to use it: the
first publish run of a new repository either works or fails with 401. On a
401, stop and ask; never create a key, and never put one in a repository
secret or a file.

**The script.** From the umbrella root, on a clean and up-to-date `main`:

```bash
scripts/graduate-library.sh --prepare-only <name>   # nothing on GitHub yet
scripts/graduate-library.sh <name>
```

`--prepare-only` runs the preflight and builds the stand-alone tree in a
scratch clone with the local gates, and stops. Do that first: a hex package
name is claimed by its first publish and can never be released, and the name
in `mix.exs` is permanent from the moment `main` exists. The full run then:

1. refuses unless the tree is clean, `main` matches `origin/main`, and
   `mix hex.build` succeeds for the app (a git dependency fails it; hex takes
   hex packages only, which is why `managoat_sandbox` waited for the Sprites
   client's hex release, pinned exactly to `0.2.0` for the reason in its
   `mix.exs`);
2. `git subtree split -P apps/managoat_<name>` puts the app's history on
   `graduate/<name>` (one commit per app today, the extraction PR; an
   `--unshallow` fetch first if the clone is shallow);
3. creates the repository (public, no wiki, topic `managoat-library`) and
   pushes the split as `main`;
4. in a fresh clone, copies the template in, takes the three umbrella path
   lines out of `mix.exs`, points `@source_url` at the new repository, adds
   `ex_doc` (so `mix hex.publish` publishes hexdocs too), credo and dialyzer,
   writes the repository's own `mix.lock`, runs compile, credo, the tests and
   `mix hex.build` locally, and pushes `chore: stand alone (...)`. That push
   is what runs CI and the first publish;
5. creates the `no-release` label and protects `main` behind the two checks,
   `ci` and `release gate`, with no review requirement, since a library
   repository's `main` is what publishes and the gate is what keeps it honest.

It is idempotent after a failure in 4 or 5: rerun it and it skips what exists.
The template it copies mirrors the SDK's release automation
(`.github/workflows/sdk-publish.yml`, `sdk-release-gate.yml`,
`scripts/sdk-release.mjs`): `scripts/release.exs state` reads `@version` from
`mix.exs` and asks hex whether it exists; `guard <base>` fails a PR that
changes `lib/`, `priv/` or the consumer-facing part of `mix.exs` without a
bump, a bump whose version hex already has, or a bump without a
`## [<version>]` heading in `CHANGELOG.md`. Merging a bump publishes and tags
`v<version>` as a record; a docs-only merge finds nothing to do. The template
carries a Postgres service block that only `managoat_oauth` keeps (the script
strips it for the others) and action pins copied from `ci.yml`; Dependabot
maintains them from there, and the checkout-pin trap from this repository
applies: a Dependabot bump can move the SHA and leave the version comment
behind, so trust the SHA.

**What the script does not do: the Fountain-side PR.** One per library, opened
only after the hex release exists and only after the previous library's PR has
merged (two open at once conflict on `apps/fountain/mix.exs`, the Dockerfile
and `CLAUDE.md`):

- delete `apps/managoat_<name>`;
- `{:managoat_<name>, in_umbrella: true}` becomes
  `{:managoat_<name>, "~> 0.1.0"}` in `apps/fountain/mix.exs`;
- drop its `COPY apps/managoat_<name>/mix.exs` line from the Dockerfile;
- `mix deps.get`, then `mix deps.unlock --unused`;
- the layout block in `CLAUDE.md`, the "Built so far" block in
  decisions/0037 (then `scripts/decisions-index.sh` and
  `okf validate decisions`), and a `[Unreleased]` line here in `CHANGELOG.md`;
- the gates: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `MIX_ENV=dev mix dialyzer`, the full root suite with
  every remaining library's banner at `0 failures`,
  `umbrella_layout_test.exs`, `scripts/test-libraries.sh`, and
  **`docker build --target build .`**. The last one matters most: the
  Dockerfile's deps layer is the only consumer of the hex release that CI does
  not exercise, since CI never builds the image. After the merge, watch
  `build.yml` on `main` go green.

`umbrella_layout_test.exs` and `scripts/test-libraries.sh` walk whatever
`apps/managoat_*` directories remain, so they need no edit per library; the
last library out relaxes the "at least one library" assertion and makes the
script exit 0 with a message on zero apps. The `config :managoat_*` lines in
`config/*.exs` stay: a hex dependency reads its otp_app configuration the same
way an umbrella app did.

**Ordering: a library that depends on another graduates after it.** Hex
refuses `in_umbrella` dependencies, so the dependency must be on hex first.
`managoat_runner` depends on `managoat_sandbox` and is the worked example:
sandbox graduates to hex; sandbox's Fountain-side PR deletes
`apps/managoat_sandbox` **and, in the same PR**, changes
`apps/managoat_runner/mix.exs` from `{:managoat_sandbox, in_umbrella: true}`
to `{:managoat_sandbox, "~> 0.1.0"}`, because an `in_umbrella` dependency on
an app that no longer exists cannot resolve, so the switch cannot be a PR of
its own after the deletion. The umbrella then resolves it from hex like
Fountain does, `mix hex.build` for runner succeeds inside the umbrella (that
PR's gate), the runner conformance suite still passes; then runner
graduates.

**The cost that starts on graduation day.** A change across the seam is two
PRs: a bump in the library (its gate insists), then a pin in Fountain. The
version pins here are `~> 0.1.0`, patch-level while every library is 0.x, so
a library's `0.2.0` reaches Fountain only when someone bumps the pin, on
purpose. Under this repository's ruleset a solo merge is
`gh pr merge --admin`, and a merged-PR branch push runs no CI here, so the pin
PR is the only place the new version is exercised against Fountain; do not
skip its gates. Merges into a library repository are yours once its CI is
green, because its `main` is what publishes.

## Changing the API

The server's OpenAPI document is the wire contract, and four clients live in
this repository against it. A schema change that reaches only one of them is
the failure mode this section exists to prevent, so the checks are arranged to
fail in the PR that makes the change rather than in somebody's application
months later.

If you touched `apps/fountain/lib/fountain_web/schemas.ex`, a controller's
`operation/2`, or the router, rebuild the contract first:

```bash
scripts/sdk-contract/build.sh
git diff --stat sdk/contract/contract.json
```

An empty diff means the wire did not move and you are done. A non-empty diff
is the list of what every client now has to agree with. Work through it:

```bash
cd sdk/typescript && npm run generate && npm run verify-contract
cd sdk/python     && python3 scripts/verify_contract.py
cd sdk/elixir     && mix test test/contract_test.exs
swift test --filter ContractTests        # from the repository root
```

Each verifier reads `sdk/contract/contract.json` and its own manifest under
`sdk/contract/manifests/`, and names itself and the exact field, operation or
enum value that no longer lines up. Fix the client, then update its manifest
to describe what it now depends on. `sdk/contract/README.md` is the reference
for the manifest format and for what each of the five checks means.

Two things that are not optional:

- **A new endpoint needs a decision.** `scripts/sdk-contract/build.sh --check`
  fails when an operation is neither claimed by a manifest nor matched in
  `sdk/contract/omissions.json`. Either wire it into a client, or add it to the
  allowlist with one line saying why no client needs it.
- **Commit `sdk/contract/contract.json`.** It is committed so the Swift job,
  which has no Elixir toolchain, can check against it. `dist/openapi.json` is
  the rebuilt input and stays ignored.

### The schema has to match its own controller

`sdk/contract` and `sdk/conformance` both compare a schema with another schema,
so neither notices when the document is wrong about what the action actually
renders. Three defects of that shape landed in a day (#1417, #1418, #1427), so
the suite now checks it directly and you will meet it without doing anything:

- **Every response any controller test renders** is validated against the
  schema its operation declares. The check is attached in `test_helper.exs` and
  costs nothing per test; 146 operations are covered by tests that already
  exist. A failure names the operation, the mismatch and the body.
- **`apps/fountain/test/fountain_web/schema_guardrail_test.exs`** adds what a
  rendered response cannot show: that no `required` list names a property its
  schema lacks, that no response is declared as an object with no properties,
  and — for the operations on its short list — that the action renders *every*
  property the schema declares, which an optional field never sent would
  otherwise hide.

If you hit it, the schema in `apps/fountain/lib/fountain_web/schemas.ex` is
usually the thing that is wrong, not the action. When it genuinely cannot be
fixed in that PR, add the `{operation, status}` pair to
`FountainWeb.SchemaGuardAllowlist` with a reason and an issue, and raise
`@ceiling` in the guardrail test in the same diff — that number moving is the
signal to a reviewer. The list may shrink freely; deleting a line is how a fix
finishes.

### Changing behaviour rather than shape

The contract above covers request and response *shape*. What a client does with
that shape — SSE framing, reconnect and cursor resume, which error class a
status becomes, terminal run states, the permission flow, pagination — is the
shared conformance suite in `sdk/conformance/`, run by all four clients from
one set of JSON scenarios.

Change one of those behaviours and the scenario is where you start, before any
client changes:

```bash
$EDITOR sdk/conformance/scenarios/<name>.json
python3 sdk/conformance/lint.py
```

The lint checks the format, checks the support matrix, and checks every fixture
body against the schema the server declares for that operation, so a scenario
cannot go green against a response the real server would never send. Then run
the four adapters:

```bash
cd sdk/typescript && npm run conformance
cd sdk/python     && python3 -m unittest discover -s tests -p test_conformance.py
cd sdk/elixir     && mix test test/conformance_test.exs
swift test --filter ConformanceTests        # from the repository root
```

A client that cannot pass a scenario yet gets an entry in
`sdk/conformance/matrix.json` saying what it does instead and the issue
tracking it. `lint.py` refuses a skip with no issue number, so a gap is always
something somebody decided and filed. `sdk/conformance/README.md` is the
reference for the scenario format and the shared vocabularies.

Do not bump an SDK's version because the contract moved. Merging a version bump
publishes that SDK, so a version moves when its own public surface changes.
Label a PR `sdk-no-release` where the distinction needs saying out loud.

## Pull requests

Every change goes through a PR and the CI gate must pass. Do not push directly
to `main`.

If your change is architecturally significant, or constrains future work, write
an ADR using [`decisions/0001-template.md`](decisions/0001-template.md) and
refresh the index (`scripts/decisions-index.sh`) in the same PR.
