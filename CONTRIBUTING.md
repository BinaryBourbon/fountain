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

Contributions are **inbound=outbound**: when you open a pull request you
license your work to the project under the license already covering the files
you touched, and under no other terms. There is no copyright assignment and
there is no Contributor License Agreement. You keep the copyright in your work.

The practical consequence, stated plainly so nobody is surprised later: because
there is no CLA, the maintainer cannot relicense your contribution either. That
is deliberate. It means the AGPL guarantee is as binding on Fountain's
maintainer as it is on anyone else who runs a modified copy.

## Sign your commits (DCO)

Fountain uses the [Developer Certificate of Origin](https://developercertificate.org/).
It is a one-line assertion that you wrote the patch, or otherwise have the right
to submit it under the license above. Add it with `-s`:

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
docs gates. If you touched `docs/`, run those too:

```bash
mkdocs build --strict
python3 scripts/docs-style.py
vale lint docs
```

## Pull requests

Every change goes through a PR and the CI gate must pass. Do not push directly
to `main`.

If your change is architecturally significant, or constrains future work, write
an ADR using [`decisions/0001-template.md`](decisions/0001-template.md) and
refresh the index (`scripts/decisions-index.sh`) in the same PR.
