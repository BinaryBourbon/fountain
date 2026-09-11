---
type: ADR
title: "A merge queue tests what it merges"
description: "Main takes ~26 merges a day and half land a tree no CI run ever tested; a GitHub merge queue builds the merge result before it merges, and the review requirement drops to zero because it was bypassed on every solo merge anyway."
tags: [ci, process, github]
status: stable
adr: "0050"
adr_status: "Accepted"
date: 2026-09-10
generated: { by: claude-opus/5, at: 2026-09-10T12:00:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-10T12:00:00-04:00 }
---

# 0050 — A merge queue tests what it merges

**Status:** Accepted. Built: the `merge_group` CI plan, the tree-proof link
from a queue run to main, and `require-checks.py --merge-queue`. The ruleset
itself is external state, so the queue is live only once that command has been
applied.

## Context

Main took 775 merges in the 30 days to 2026-09-10 — about 26 a day, peaking at
55. A PR that was green an hour ago was green against a different main.

The repository already knew this. `already-tested` skips main's re-run only
when the pushed tree equals a tree some PR run actually tested, and it misses
roughly half the time: measured over 100 recent pushes to main, 53 skipped and
the rest ran the full suite because the branch was one or two commits behind at
merge. Those misses are not a defect in the probe. They are the honest report
that **half of what lands on main is a tree no CI run has ever seen.**

What that is *not* is a crisis of correctness: main failed 4 times in 300 push
runs (1.3%). The cost is elsewhere. Every miss is a full ~12 minute re-run on
main, it delays the deploy that is gated on main's CI, and it blocks the
build-in-PR-and-retag idea outright, because a PR-built image is reusable only
when the merged tree is the tested tree.

Two constraints shaped the design more than the volume did:

- **The organization is on the free plan: 20 concurrent GitHub-hosted jobs.**
  One full CI run is 19 of them. A burst of ten agent-opened PRs on 2026-09-10
  produced a run whose jobs waited 29 minutes before starting and then finished
  in 7. Runner concurrency, not test time, is what this repository runs out of.
- **72% of open PRs are stacked** — 31 of 43 target another PR's branch rather
  than main. GitHub only queues a PR based on the protected branch.

## Decision

Merges go through a GitHub merge queue. `gh pr merge <N> --squash --auto`
queues a PR; the queue builds the exact tree the merge would produce and merges
only if that tree passes.

CI learns a third event. `gate.py`'s `PROBES` table is the authority: a
`pull_request` runs the `changes` classifier, a `push` runs the
`already-tested` probe, and a `merge_group` runs **both** — it classifies the
group like a PR, and it skips the group outright when the group's tree is one a
PR run already tested. A merge group publishes the `tested-tree` artifact, and
main's push finds it through the queue's
`gh-readonly-queue/<base>/pr-<number>-<sha>` branch name, which is the only
link back from a squashed commit to the run that tested it. A queued merge
therefore costs one full run, not two.

The queue builds one group at a time (`max_entries_to_build: 1`) and buys its
throughput by batching up to five PRs into that group instead, because
speculating two groups deep cannot run two groups on a 20-job ceiling — it
queues the second behind the first while starving every open PR.

Two rules come off, and each was already off in practice:

- **The up-to-date requirement**, because it was an approximation of "tested
  against what it will merge into" and the queue tests that directly. Keeping
  both only forces rebases to prove what the queue is about to prove properly.
- **The review requirement**, from 1 approving review to 0. A solo-authored PR
  could never satisfy it, so every merge here was `gh pr merge --admin` — and
  an admin merge skips the queue. A review requirement that is bypassed on
  every merge is not a gate, and leaving it on is the difference between a
  queue every PR goes through and a queue nothing goes through. The
  `pull_request` rule itself stays, so main still refuses a direct push.

## Consequences

Main stops accepting untested trees, `already-tested` hit rate goes to
essentially 100%, and build-in-PR-and-retag becomes possible for the first
time (its own prerequisite, `BUILD_SHA` baked into the image, is unchanged and
still has to be injected at deploy time).

Merging stops being instant. A lone PR waits up to five minutes for company
before it even builds, which is the cost of batching under the job ceiling.
Nothing should wait on a queued PR synchronously.

A queued PR can be ejected. That is the mechanism working: the failure is the
change against a main it had never been tested with. It stays open with the
failure attached.

**Stacks do not change.** A stack still lands one stage at a time, because only
the tip targets main. What changes is that GitHub performs the retarget when
the parent merges, which removes the trap where a stale base merged cleanly
into a branch that no longer existed.

CI spend rises. A merge that today skips main entirely now pays for a queue
run. Batching is what keeps that from being a straight doubling, and the
docs-only classifier still runs in the queue, which matters for the 11% of
merges (85 of 775) that touch nothing but markdown.

The bypass remains. Organization admins can still merge past the queue, so the
guarantee is a matter of discipline rather than enforcement; CLAUDE.md says so
in *Things NOT to do*.

## Alternatives considered

- **Rebase before merging, no queue** — the cheap version of the same lever,
  and it was the standing advice before this. It depends on remembering, it
  does not survive a burst of agent-opened PRs, and it cannot batch.
- **Keep the review requirement and queue only reviewed PRs** — leaves a
  permanent `--admin` path for hand-authored PRs, so the queue covers part of
  the traffic and main still takes untested trees from the rest.
- **A smaller PR run, full suite only in the queue** — the mature pattern, and
  the right answer if CI spend becomes the binding constraint. It trades away
  PR feedback quality, which is the thing agents working here depend on most.
- **More runners** — addresses the 20-job ceiling but not the untested-tree
  problem, which is the actual finding.
