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

Three CI events now exist, and `gate.py`'s `PROBES` table is the authority on
what each one owes:

| Event | Probes that run | What the plan means |
|---|---|---|
| `pull_request` | `changes` | Classify the diff; docs-only skips the Elixir suite |
| `merge_group` | `changes` + `already-tested` | Classify the group, and skip it outright when its tree is one a PR run already tested |
| `push` | `already-tested` | Main reuses the queue run (or a PR run) that tested this tree |

The queue run and main's push both look for the `tested-tree` artifact, so a
queued merge normally costs one full run, not two: the queue runs the suite,
and main's push finds the queue's artifact and finishes in seconds. Main finds
it through the queue's `gh-readonly-queue/<base>/pr-<number>-<sha>` branch
name, which is the only link back from a squashed commit to the run that
tested it.

### Sizing

`MERGE_QUEUE` in `require-checks.py` carries the reasoning for each value. The
binding constraint is the free plan's 20 concurrent GitHub-hosted jobs against
a full CI run's 19, which is why the queue builds one group at a time and buys
its throughput by batching up to five PRs into that one group instead.
Revisit `max_entries_to_build` when the concurrency ceiling changes, not
before.

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
