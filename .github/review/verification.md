# Fountain verification

The service uses the base policy and setup bytes, checks out the exact PR head
on a separate machine, and records command exit/output evidence. Setup installs
OTP 28.3, Elixir 1.19.2, Node 24.20.0, Go 1.26.0, Hex 2.5.1 and Rebar 3.25.1,
and starts the supported Ubuntu image's packaged PostgreSQL (16 or 18) on
loopback. GitHub CI also verifies PostgreSQL 16. Commands use rl-env so tool paths and
the disposable database settings survive between shells. No Fountain login,
GitHub write token or provider credential belongs in this machine.

Independent verification runs all six core and ee test partitions sequentially
using the upstream runner's nonzero-test and coverage-export guards, then runs
every sibling app's suite and root umbrella tests in one VM. The root run catches
cross-app configuration leaks that separate CI partitions cannot. It covers the core `mix precommit` stages: compilation,
unused-dependency/lockfile checks, formatting, Credo, Dialyzer in dev, security
scanning, release assembly in prod, and tests. Commands fail fast, including grouped stages that keep the policy within
20 entries; any failed stage makes verification incomplete. Plain `mix deps.get` preserves dev/test dependencies
when preparing prod. It also checks the wire contract, conformance fixtures, the TypeScript,
Python and Elixir SDKs, both Go modules and the Hermes plugin. Each command must
exit successfully; a failed stage is not excused by a later successful one.

The complete GitHub CI workflow additionally supplies the six-way partitioned
coverage gate, release boot, generated-type freshness, Swift on Linux
and macOS, docs prose, core distribution and Compose checks. The secret scan
always applies. Other required workflows follow the actual SDK, ADR and sandbox
image path filters in the base policy. Only success for the recorded PR, head
and base counts. The dispatch job only acknowledges admission.

A missing tool, absent workflow result, stale contract, setup failure, empty
test run or exhausted deadline leaves incomplete work. Do not skip tests, lower
coverage thresholds, rewrite verification scripts or add release-bypass labels
to obtain approval. Docs-only PRs still receive independent core verification
in this initial recipe; their conditional GitHub CI path is preserved.
