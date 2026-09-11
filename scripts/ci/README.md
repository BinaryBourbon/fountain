# CI maintenance

`CI required` verifies the selected job plan. A skipped required job is a
failure, unless the classifier selected docs-only CI or the main probe proved
that a successful PR run checked the identical tree. The proof is the
`tested-tree` artifact, uploaded after the aggregate gate passes. Expired or
missing evidence triggers full CI.

Main commits validate independently, so a burst of merges cannot cancel an
older pending validation or wait behind an unrelated run. Superseded PR runs
still cancel. Image builds retain the built-ancestor diff, which includes all
image-affecting changes since the last built ancestor.

## Activate required checks after merging

The repository ruleset is external state, so opening this PR does not change
merge permissions. Once the workflow is on main and its checks have passed:

```sh
# Inspect the complete update, preserving the existing rules and bypass list.
python3 scripts/ci/require-checks.py > /tmp/fountain-required-checks.json
cat /tmp/fountain-required-checks.json
# Apply only after review. This refuses until both checks pass on main.
python3 scripts/ci/require-checks.py --apply
```

This requires `CI required` and `Detect secrets` from GitHub Actions. It
preserves an existing status rule's strictness if one already exists. Run the
preview again after applying to verify the stored policy.

## The merge queue

`--merge-queue` adds the queue rule and turns the up-to-date requirement off,
because the queue supersedes it: instead of asking a PR to prove it was rebased
recently, the queue builds the exact tree the merge will produce and merges
only if that passes.

It deliberately does **not** touch the review requirement. A PR still needs its
approving review before GitHub will enqueue it at all — an unreviewed PR does
not fail, it simply never enters the queue, which is worth knowing before
debugging a `--auto` that appears to do nothing.

```sh
python3 scripts/ci/require-checks.py --merge-queue    # preview
python3 scripts/ci/require-checks.py --merge-queue --apply
```

`--apply` refuses unless `ci.yml` and `secrets-scan.yml` **on main** carry a
`merge_group:` trigger. That order is the one failure that has no visible
cause: a queue whose required checks never start does not fail a PR, it waits
out `check_response_timeout_minutes` and ejects it, with no red job anywhere to
explain why. `test_every_event_the_workflow_triggers_on_is_a_plan` in
`test_gate.py` keeps the workflow and `gate.py` from drifting apart later.

Four CI events now exist, and `gate.py`'s `PROBES` table is the authority on
what each one owes:

| Event | Probes that run | What the plan means |
|---|---|---|
| `pull_request` | `changes` | Classify the diff; docs-only skips the Elixir suite |
| `merge_group` | `changes` + `already-tested` | Classify the group, and skip it outright when its tree is one a PR run already tested |
| `push` | `already-tested` | Main reuses the queue run (or a PR run) that tested this tree |
| `workflow_dispatch` | `changes` | Run the complete plan, without diff-based skips or tree reuse |

The queue run and main's push both look for the `tested-tree` artifact, so a
queued merge normally costs one full run, not two: the queue runs the suite,
and main's push finds the queue's artifact and finishes in seconds. Main finds
it through the queue's `gh-readonly-queue/<base>/pr-<number>-<sha>` branch
name, which is the only link back from a squashed commit to the run that
tested it.

### Sizing

`MERGE_QUEUE` in `require-checks.py` explains the queue settings. A full mixed
PR runs 26 jobs; a full merge group runs 27 because both probes run. The
documented limit is 20 concurrent runners. The queue builds one group at a
time and batches up to five PRs. Revisit
`max_entries_to_build` when the concurrency limit changes.

## SDK jobs

The Elixir, Python and TypeScript SDKs run in `elixir-sdk`, `python-sdk` and
`typescript-sdk`. The Go CLI, Hermes plugin and deployed-runner checks run in
`cli-plugins`. The Swift job (`swift-sdk`) runs on Linux and
macOS. Each reads the committed contract; `release-and-contract` checks its
generation.
The Elixir job owns its toolchain, cache, formatting, compilation, tests, docs,
package dry run, contract and conformance checks. It tests Elixir 1.15.8
with OTP 26.2.5.21 and Elixir 1.19.2 with OTP 28.3. Formatting uses 1.19.2
because formatter output differs between versions; all remaining checks run
on both pairs. The Python job owns its
tests, compilation, contract and conformance checks on Python 3.9 and 3.13.
Both legs also build an sdist and wheel, install the wheel in a fresh virtual
environment and run the SDK regression suite against that installed package.
This replaces the full source-tree test run; separate contract and conformance
steps retain their focused diagnostics.
The verifier checks the type marker, package version and every SDK import path.
These cover the package minimum and newest declared runtime. Both legs must
pass; a failure does not cancel the other leg. The TypeScript job owns
installation, type checks, tests, builds, browser bundling, contract and
conformance checks on Node 20.19.0 and 24. The minimum runtime runs compiled
JavaScript from the same test sources in a temporary fixture tree. Node 24
retains native TypeScript tests. Both legs build the SDK and browser bundle.
These three extracted jobs lint fixtures before their
tests. Swift retains its separate conformance test step.
`CI required` requires every selected SDK job. A failed, cancelled or
unexpectedly skipped job fails the gate. Main runs all SDKs unless a verified
tested tree authorizes reuse. Manual workflow dispatch always selects every
SDK and the full server plan, including prose checks. Both gates reject a
manual classification that attempts to skip part of that plan.

`SDK checks` reports the SDK result even when docs-only classification or a
previously tested tree skips every SDK leg. It validates the same probe
outputs as the full gate and rejects missing, failed or unexpectedly skipped
jobs. `CI required` depends on this aggregate. Only the full gate publishes
`tested-tree` evidence; passing the SDK gate cannot authorize reuse of a tree.

Register a new job in
`gate.py`'s `FULL_JOBS` and the workflow gate's `needs` list together. For an
SDK job, also update `SDK_JOBS` and the `sdk-checks` dependencies. Run
`test_gate.py` and `test_sdk_gate.py` to verify their agreement and every
supported event plan.

## SDK path classification

`changes` reports four `sdk_<language>` outputs from `sdk_changes.py`, using
its existing PR merge base or merge-group base. Each SDK job consumes its
own output. The two gates independently validate the selection and exact job
results. Missing or malformed outputs fail both gates; only explicit `false`
lets a job skip.

The classifier selects an SDK for its directory, documentation page or
registered release tooling. Shared contract and conformance files select all
SDKs. So do API implementation, build configuration and unregistered paths.
An explicit allowlist selects none for unrelated docs, console UI, server
tests and telemetry. Mixed changes select the union of their SDKs. SDK docs
select their language even on the server docs-only path.

The release job installs TypeScript dependencies and checks generated types
only when TypeScript is selected. Server wire-contract generation and its
freshness check remain required on every full server plan. Shared contract
changes select all SDKs, including that generated-type check.

Invalid bases, failed or empty diffs, malformed paths and undecodable names
select every SDK. The NUL-delimited Git diff disables rename detection, so a
move out of an SDK still selects its former owner. Outputs contain only fixed
keys and boolean values.

Register a new language in `LANGUAGES` and `OWNED_FILES`, expose its workflow
output, and add routing fixtures in `test_sdk_changes.py`. Register SDK docs
and checked snippets before the unrelated-docs allowlist. Keep contract
triggers outside that allowlist; uncertainty must select every SDK.

## Refresh partition timings

Each partition records all module timings with eight concurrent cases, matching
the allocator's cost model. A passive formatter observes test events; do not
add `--slowest-modules` to routine CI, because it forces serial trace mode and
infinite test timeouts. Download the six `coverdata-*` artifacts from one
successful full PR run into a new directory, then regenerate from their logs:

```sh
gh run download RUN_ID --pattern 'coverdata-*' --dir /tmp/fountain-ci-timings
cat /tmp/fountain-ci-timings/coverdata-*/*.timings.log \
  | elixir scripts/regen-test-timings.exs
PARTITION_DEBUG=1 elixir scripts/partition-files.exs 1 6
```

Use one run's logs, not multiple runs, because durations for modules in the
same file are summed. The artifact retention is one day. Unknown test files
still get a median estimate and run; refreshing the table improves balance.
The allocator reserves 30 seconds on partition 1 for the sibling suites,
measured at 26-34 seconds on September 5, 2026. Update that reserve when the
`Run the sibling apps' tests with coverage` step changes materially.

The core release uses a separate cache of compiled production modules. The
assembled release is rebuilt each time, including the check that toggles from
the core distribution to the bundled distribution.

## Wording reports

Style, STE and de-stink reports are advisory. Logs show the first 60 lines;
the `prose-advice` artifact retains complete output for seven days. A linter
failure is also reported as a warning. Tool installation failures still fail
the job. Compilation, links, anchors, snippets, nav and CLI docs parity remain
blocking checks in the Elixir and Go suites.

## Check the CI policy locally

```sh
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
actionlint -shellcheck= .github/workflows/ci.yml
shellcheck scripts/ci/*.sh
elixir scripts/ci/timing-formatter-test.exs
```

## Portable alert rules

The `Alert rules` workflow runs `scripts/test-alerts.py` with Prometheus
`promtool` and PyYAML. It extracts the actual PrometheusRule spec and checks syntax,
replica aggregation, failure thresholds, counter resets, absent series, low
traffic, and first-output alert hold time. Run the same command locally
after changing `deploy/k8s/prometheusrule.yaml`.
