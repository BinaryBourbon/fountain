# Fountain Review Loop

Four independent reviewers examine the entire current PR, including any fixes:

| Reviewer | Runtime / model | Focus |
|---|---|---|
| `qa-team` | Codex / GPT-6 Astra | Correctness, regression tests, database behavior, concurrency and recovery |
| `security-audit` | Codex / GPT-6 Astra | Tenant isolation, secrets, injection and authorization boundaries |
| `product-api` | Claude / Opus | Documented product intent, naming, rollout and client compatibility |
| `xp-reviewer` | Claude / Opus | Simplicity, useful tests and maintainability |

The PostHog-inspired cycle is review → triage → permitted fix → checks and
independent verification → four fresh reviews. Review Loop posts inline finding
threads and keeps one summary for the run updated. It consolidates duplicate
findings, accepts low/info suggestions as nonblocking, and retains explanations.
It resolves service-owned threads when policy permits; human objections remain
blockers until a maintainer addresses them.

Clear medium-or-higher defects can receive an automatic fix within the
configured file and path bounds. The host enforces the configured file bound,
permitted paths, three-round limit, exact-revision checks and final approval.
Confidence is a reviewer judgment, not a separate numeric score enforced by
the host. This setup does not impersonate Paul or launch an interactive
pairing agent.

A human decision is the expensive outcome, and two things produce one. A
reviewer can set `needsHuman` on a finding, which ends the run with `needs-
human-review` at any severity: the host downgrades a low or info *defect* to
nonblocking, but a low or info finding marked `needsHuman` or filed as a
`product_decision` still goes to a maintainer. The instructions therefore name
one case that always warrants `needsHuman`: a change that contradicts a
decision an Accepted ADR records, cited by ADR and sentence. Beyond that they
reserve it for a medium-or-higher finding whose remedy a maintainer must choose
and which is hard to reverse once merged (a public contract, a migration or
retention change, licensing, the authorization model, a repair outside the fix
policy), and say that a low or info finding is never one. Intent the approved
base already records is settled when the PR follows it. The other producer is
`human_review_paths`, which is now the short list of places where a wrong
automatic approval is hard to undo or would weaken a gate: the policy and these
instructions, workflows, migrations, licensing, the release and deployment
definitions, the SDK version files whose merge publishes, the gate thresholds
and scripts, and the ADRs themselves, so a PR that edits a decision always
reaches a maintainer. The first eleven runs against this repository all ended
with the label, most of them for a dependency bump, a doc, or a low finding
about wrapping or duplicated code; that is what both changes answer.

An approval covers the entire evaluated PR and never merges it. A new revision,
failed check or human objection can invalidate an earlier approval. Repository
policy and all reviewer/setup instructions come from the trusted base revision.
A PR cannot authorize itself by editing these files.

Reviewer runtimes and models are pinned in `.github/review-loop.yml`. The fixer
uses the operator-selected default. Parallelism is bounded by host and Fountain capacity. The repository policy permits four
reviewers at once, 30 tasks, 500,000 reported tokens and 120 minutes per run.
Daily budgets are separate operator settings. Neither token nor task counts
are dollar-cost reporting.

## Verification and activation

`setup.sh` installs pinned, hash-checked toolchains on a fresh Ubuntu 24.04 or
26.04 worker before PR checkout, plus a disposable local PostgreSQL database
(the supported distro major, 16 or 18). GitHub CI separately verifies PostgreSQL 16.
Twenty commands run the core/ee partitions, extension and single-VM umbrella
tests, precommit static checks, Dialyzer, prod release assembly,
contracts, SDKs, CLIs and plugin tests. The eight required workflow definitions
and their path filters were checked against Fountain main at
`539a300207728bebc5216af586e497ce07778f94`. GitHub CI additionally supplies
coverage, release boot, Swift, docs and distribution gates. No failed
gate is skipped or changed to get an approval.

An existing Go guest-handshake fixture race is tracked in
[#1641](https://github.com/BinaryBourbon/fountain/issues/1641), reproduced in
2 of 100 focused local runs on the inspected main revision. Its gate remains
enabled. A failure produces incomplete verification and a human handoff;
rerunning until it turns green is not evidence that the defect was fixed.

Deploy Review Loop support for `verification.command_timeout_minutes` first.
The expanded recipe needs a thirty-minute command allowance: its measured cold
Credo/Dialyzer stage took about 23 minutes and the full recipe about 48 minutes.
See [measured command budget](verification.md#measured-command-budget).

Merge this configuration through Fountain's normal reviewed PR process. Its
own changes require human review; no live run can use its policy before merge.
The dispatch workflow uses the public `managoat/review-loop-action` at an
immutable release commit, with no inline script. Configure repository variables
`REVIEW_LOOP_URL` to
`https://review-loop.demo.managoat.com` and `REVIEW_LOOP_ENABLED` to `true` after
the policy is trusted. The workflow admits opened, updated, reopened or
ready-for-review PRs from branches in this repository. Draft and fork PRs are
excluded. Existing PRs need a subsequent event or an explicit run from the app.

Repository access comes from the Managoat Review Loop GitHub App installation;
no Fountain login or inference secret belongs in repository Actions secrets.
To stop automatic admission, set `REVIEW_LOOP_ENABLED` to `false`; cancel active
runs separately in Review Loop. Maintainer commands and decisions are documented
in the service's [GitHub lifecycle guide](https://github.com/managoat/review-loop/blob/main/docs/GITHUB-LIFECYCLE.md).
