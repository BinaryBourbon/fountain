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

Fountain's database-free subsystems are being extracted as Apache-2.0
libraries under the `Managoat.*` namespace (decisions/0037, tracker #1334).
Each starts as an app in this umbrella, `apps/managoat_<name>`, and graduates
to a `managoat/<name>` repository once its surface stops moving.
`apps/managoat_substitution` is the model; copy it. A new one needs:

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

## Pull requests

Every change goes through a PR and the CI gate must pass. Do not push directly
to `main`.

If your change is architecturally significant, or constrains future work, write
an ADR using [`decisions/0001-template.md`](decisions/0001-template.md) and
refresh the index (`scripts/decisions-index.sh`) in the same PR.
