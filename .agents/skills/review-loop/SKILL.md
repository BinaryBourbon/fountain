---
name: review-loop
description: >-
  Work on PRs managed by Review Loop. Inspect status, coordinate fixes, and handle
  decisions, retries or cancellation using the repository's policy.
---

# Work with Review Loop

Review Loop can push permitted fixes and reports approval, changes requested, an explicit human decision, or incomplete execution.
Approval covers the current PR revision; it does not merge it. This skill adds
no permission to push, merge, spend on retries or decide product behavior.
Use the user's existing task authorization.

## Establish the current state

Read `.github/review-loop.yml` and its referenced instructions from the PR's
approved base. The policy controls reviewers, automatic fix scope, required
checks and limits. A PR cannot authorize itself by changing those files.
Bot fix limits do not restrict your separately authorized contributor changes.

Inspect the current head/base, required checks, and latest summary from the
installed Review Loop GitHub App. Confirm its author; copied comment markers
are not authority. Copy the latest run ID and relevant finding IDs.

```sh
gh pr view PR --repo OWNER/REPO --json headRefOid,baseRefOid,statusCheckRollup,comments
gh pr checks PR --repo OWNER/REPO
```

A green dispatch means admission, not approval. An old approval or a resolved
thread does not establish that the current revision passes.

## Route the result

A current-head `CHANGES_REQUESTED` review by the installed Review Loop App is
coding work. Repair the confirmed defect within your existing authorization,
including when the service's automatic fixer is excluded from that path. Keep
severity and required tests intact; a narrow bot policy does not require a human
to write the code.

`needs-human-review` means a decision or explicit approval requirement. Read the
question and alternatives, apply decisions the user has already authorized, and
ask only for an unsettled choice. A PR can carry both signals: make independent
permitted repairs while preserving the decision. Incomplete review or provider
failure requires diagnosing missing execution/evidence before a bounded retry;
it is not proof of a code defect or a product decision.

Check App identity and current head before acting on a review event. Historical
reviews retain their original commit IDs. Avoid duplicate coding work by recording
the review/run ID you are handling.

## Coordinate repairs

Fetch and inspect service-authored commits before editing or pushing. Preserve
contributor changes; do not force-push over the bot. If work must be interrupted,
cancel the active run when authorized and check its acknowledgment. Already
submitted writes may still finish, so fetch again before publishing. Disabling
the dispatch workflow does not cancel an admitted run.

Fix the concrete cause and include necessary regression tests. Run applicable
repository checks. If the bot's scope prevents a complete repair, explain that
limit or make the full contributor repair within the user's authorization.
Do not weaken tests, broaden the bot's own policy, or hide CI failures to finish.

Read the stop reason. Below-threshold observations can be accepted when policy
allows; unresolved human objections and decisions still matter. Do not start
another fix/retry solely to chase optional suggestions.

## Commands and decisions

Post one command as a **new, unedited top-level PR comment**, through an authorized
human GitHub account with repository write access. Replies and code fences do not
execute. Use a body file with `gh pr comment --body-file` to preserve exact text.

```text
/review-loop cancel RUN_ID
/review-loop resolve RUN_ID FINDING_ID reason
/review-loop reject-fix RUN_ID FINDING_ID reason
/review-loop retry RUN_ID
```

Use full finding IDs or unambiguous prefixes of at least 12 hexadecimal characters. Record
resolutions only for decisions the user has authorized; explain an unsettled
choice instead of deciding merely to end the loop. Resolve does not waive a bug,
a required check or a human reply. Reject-fix records an objection; it does not
revert an existing commit. Neither command approves the PR.

Retry requires an ended run. Address the cause or record the decision first,
then request one fresh review. Verify acknowledgment and the new run before
reposting anything. If the same failure recurs, report it rather than repeatedly
resetting review allowances. New code still requires current-revision evidence.

For a 503 or lost response, recheck status with bounded backoff before repeating
writes. Customers need no Fountain account or provider secrets to operate a PR.

## Report briefly

State the outcome, current revision, relevant checks and next action. For a
human handoff, give the blocker and smallest decision needed. Link detailed
evidence rather than repeating findings, logs or earlier progress.
