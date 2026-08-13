# 0017 — Suspend idle sandboxes instead of destroying them

**Status:** Accepted (built in the PR that added this document)
**Date:** 2026-08-13

## Context

Since #233, both lifetime bounds destroyed the sprite: the ConversationServer
called `Sprites.destroy` when a conversation crossed the idle timeout or the
max-lifetime ceiling, and the reaper's abandoned-sandbox pass did the same for
rows whose server had died. The design was chosen under the premise that an
idle sprite bills indefinitely — the motivating incident was a sandbox idle
for 83 days.

That premise was wrong. Sprites scale themselves to zero when idle and cost
approximately nothing while suspended; the sprite does not need Fountain's
help to stop billing. Meanwhile #649 measured what the destroy costs: the
runtime's session lives in the sandbox's filesystem, so resuming onto a fresh
sprite fails on every path we have (`claude --resume` answers "No conversation
found with session ID"; ACP `session/resume` answers `-32002 Resource not
found`). Every idle reclaim guaranteed the agent's amnesia to save money we
were not spending. The response at the time (#651) was honest UX copy; #664
raised the production idle bound to four hours so human-gated incident
conversations would survive review — treating the symptom, because the disk
loss itself was assumed to be the price of cost control.

## Decision

Split the two bounds by what they actually protect against:

- **Idle timeout → suspend.** The ConversationServer stops, the sprite is left
  alone (it scales to zero on its own), and the sandbox row parks in a new
  `suspended` status. The next prompt reattaches to the same sprite through
  the existing reuse path — same disk, same runtime session, real resume.
- **Max lifetime → destroy**, unchanged. The ceiling exists for the
  conversation that never stops being busy; it fires with a detachable
  session still running on the sprite, and parking would leave that exec
  burning unattended. Its price — the #649 session loss — is still stated
  honestly in the stage message.

`suspended` means: sprite alive at sprites.dev, no ConversationServer, woken
only by the next prompt. It is excluded from the concurrency quota (a parked
sprite is not compute; waking one re-runs the quota gate under the same
advisory lock as creation) and from boot rehydration (parked conversations
wake on demand, not on deploy).

The max-lifetime clock measures a **continuous run**, not calendar age:
`sandboxes.last_resumed_at` is stamped on each wake from `suspended`, and the
ceiling is measured from `last_resumed_at || inserted_at`. A deploy reattach
of a `ready` row stamps nothing, so restarts still cannot reset the ceiling —
the property #233 encoded — while a conversation parked for a week is not
destroyed the moment it is woken.

## Accepted costs

- **Suspended sandboxes are never aged out.** Sprites accumulate per tenant at
  sprites.dev indefinitely. This is deliberate: the parked-sprite cost is
  treated as zero, and the disk is the agent's memory. If that cost stops
  being ignorable — or a sprites.dev account-level sprite cap starts binding —
  a retention bound for `suspended` rows is the knob to add, with the #649
  caveat attached.
- **Usage metering blurs at the edges, in both directions.** A sandbox that
  suspends and later terminates includes its parked time in the
  `sandbox_terminated` `duration_ms`; one that stays suspended forever emits
  no `sandbox_terminated` at all, so billed sandbox-minutes understate. The ee
  usage-event vocabulary is closed and suspend-aware metering was not worth
  new event types while the cost is treated as zero. A `suspended → ready`
  wake deliberately emits no second `sandbox_provisioned`.
- **A rolling deploy has a one-time loss window.** An old node waking a
  suspended row does not recognise the status, provisions a fresh sprite, and
  the parked disk is destroyed by the reaper. Old nodes cannot *write*
  `suspended` (their changeset rejects it), so the window is read-only and
  self-limiting.

## Consequences elsewhere

- The reaper's abandoned pass splits on which bound fired: idle → park to
  `suspended` (audited as `sandbox.suspended`, actor `system:sandbox_reaper`),
  max lifetime → terminate as before. A grace window on `updated_at` keeps it
  from parking a row mid-wake, before the new server registers in Horde's
  async registry. Suspended rows match no reaper pass.
- Every sweep that destroys sprites had to learn the status, because the
  reaper's leak pass only touches terminal rows: account deletion
  (`Deletion.@non_terminal`) and tenant suspension (`_unsafe_reap_all_for_user`)
  both include `suspended` explicitly. The quota's active-status list must
  **never** include it — those two lists now differ on purpose.
- The admin sandbox view ("anything non-terminal") and the quota counter
  ("compute only") now legitimately disagree about a suspended sandbox.
- The production `SANDBOX_IDLE_TIMEOUT_MINUTES=240` override (#664) is
  reverted: suspension is lossless, so the stock idle bound no longer
  endangers human-gated incident conversations.
