---
type: ADR
title: "A bounded, opt-in queue in front of the sandbox concurrency cap"
description: "sandbox_requests holds work that hit the cap when the caller opted in (queue: true on the API; scheduled runs always) — bounded at 10 deep and one hour's wait, past which today's refusal returns; drained event-driven from update_sandbox/2's slot-freeing transitions with a five-minute cron backstop; the refusal stays the default API contract. Amends ADR 0005."
tags: [sandbox, billing, quotas, api]
status: stable
adr: "0030"
adr_status: "Accepted"
date: 2026-08-23
generated: { by: human:mdonigian, at: 2026-08-23T20:30:00-04:00 }
verified: { by: human:mdonigian, at: 2026-08-23T20:30:00-04:00 }
---

# 0030 — A bounded, opt-in queue in front of the sandbox concurrency cap

**Status:** Accepted. Everything described here is built: `Fountain.SandboxQueue`
and its `Request` schema, `Workers.SandboxQueueDrainer`, the poke in
`Conversations.update_sandbox/2`, the `queue: true` branch in
`ConversationController.create/2`, `FountainWeb.SandboxQueueController`
(list/cancel), the unconditional opt-in in `Team.Schedules.run_schedule/2`,
and the corrected pricing/docs copy. Covered by `sandbox_queue_test.exs`,
`sandbox_queue_drainer_test.exs`, `sandbox_queue_controller_test.exs`, the
queue cases in `conversations_start_test.exs` and `marketing_pricing_test.exs`,
and the guardrail entries for the new audited mutations.

Amends **ADR 0005**, which stands except where this says otherwise: the cap
still guards sandbox-row creation under the per-user advisory lock, and
refusal is still what a start at the cap gets *by default*. What changes is
that a caller may now choose to wait, within bounds.

## Context

ADR 0005 put the concurrency cap in front of sandbox-row creation and made it
refuse. #1026 then found the pricing page promising a queue that did not
exist, and #1027 corrected the copy to say "refused rather than queued" —
naming the queue as different work. This is that work (#1033).

The case that makes it worth building is the scheduled teammate run: a cron
firing into a refusal is lost work nothing retries. A 09:00 standup run that
hits a cap set by a fan-out at 08:59 simply does not happen, and the next
tick is an hour away. A script can retry a 429; a cron cannot.

The tension, stated in #1026 and not dodged here: the refusal is an upgrade
lever. A queue that always completes the work, just later, quietly removes
the reason to buy a bigger tier.

## Decision

**Queue within bounds, refuse past them, and say so.** The middle position:
the customer sees the cap, feels the wait, and still meets a refusal when the
backlog is genuinely tier-shaped. The bounds are the product decision, not a
tuning detail: a queue with no ceiling turns "refused" into "accepted and
never runs", which is a worse answer than either honest one.

- **Opt-in, never silent.** The API contract every existing client holds —
  429 `sandbox_quota_exceeded` at the cap — is unchanged. `queue: true` on
  the create body is answered `202 Accepted` with a `sandbox_request` when
  the cap is hit; without it, today's 429. Scheduled runs opt in
  unconditionally (they are the motivating case), deduplicated per schedule
  so an hourly cron stacking on a full cap holds one queued run, not one per
  tick. Interactive wakes do not queue: a human waiting on an open
  conversation can retry, and a wake that silently waits reads as a hang.

- **A queued request is its own row, not a conversation status.**
  `sandbox_requests` holds `kind: "start"` (the original create attrs,
  JSON-safe — image-carrying requests stay refusals) or
  `kind: "schedule_run"` (a schedule id, re-fired through `run_schedule`).
  A queued start has no sandbox; a `queued` conversation status would leak
  into every list view, the SSE stream and the SDK's status enum. The
  conversation exists only once the slot is won — and is then created by the
  same `start_conversation/2` as any other, re-checking suspension, billing
  and the cap under the advisory lock at drain time, not at enqueue time.

- **Bounds: 10 deep, one hour's wait** (`:sandbox_queue_max_depth`,
  `:sandbox_queue_max_wait_seconds`). At depth, enqueue returns the same 429
  the caller opted out of. Past the wait, the request expires with an audit
  event — work nobody is waiting for must not fire hours later. The depth
  check is check-then-insert without a lock, deliberately: the race
  over-admits a queue entry, never a sandbox — the cap itself is still
  enforced under `Quotas.with_sandbox_reservation/3` when the slot is won.

- **Drain on slot-free, not on a timer.** `Conversations.update_sandbox/2`
  is already the documented choke point for every status change; a
  transition out of the cap-counting statuses (`pending`/`starting`/`ready`)
  into `terminated`/`failed`/`suspended` pokes `Workers.SandboxQueueDrainer`
  (Oban, unique per user for 30s). Terminate, fail, suspend (ADR 0017 —
  suspension frees the slot) and the reaper's stuck-row release all pass
  through that function, so no slot-freeing site can forget. The
  five-minute cron firing is the backstop and the expiry sweep, never the
  primary trigger.

- **Fairness is per tenant twice over.** The drain job is keyed by user and
  the slot is won under the per-user advisory lock, so one tenant's backlog
  cannot delay another's — the same property the reservation already had.

- **Visibility.** The 202 carries the request and its 1-based position;
  `GET /api/sandbox-queue` lists what waits (list order is queue order);
  `DELETE /api/sandbox-queue/:id` withdraws a queued request. Enqueue,
  start, cancel, expiry and failure are audited as `sandbox_request.*` —
  the request's own settings never appear in the trail (ADR 0013). The
  drainer acts as `system:sandbox_queue`.

- **One broken request does not block the lane.** A drain attempt that fails
  for any reason other than the quota marks that request failed and moves
  on; the quota error stops the drain, because the slot this run was poked
  about is taken.

## Consequences

- A scheduled run that meets a full cap now waits for a slot instead of
  being recorded as failed; its schedule shows "waiting for a free sandbox
  slot" until the drainer re-fires it or the wait bound expires it.
- Scripts that opt in trade a 429-and-retry loop for a 202 and a position.
  Scripts that do not opt in see no change at all.
- The pricing copy #1027 corrected goes back the other way, with the bound
  stated: the queue delays the cap, it never raises it. The upgrade lever
  survives as the bound — a backlog deeper than 10 or older than an hour is
  tier-shaped, and meets the same refusal as before.
- Billing and suspension are enforced at drain time, so a request queued by
  an account that is then suspended does not start.
- Two new config knobs, one new cron entry, one new table. The queue table
  needs no retention window: terminal rows are small, and their lifecycle
  question (prune or keep) can wait for real data — `RetentionPruner`'s
  moduledoc rule about stated decisions applies when one is made.

## Alternatives considered

- **A `queued` conversation status** — least machinery, but every list view,
  the SSE stream and the SDK's status enum learn a state that has no sandbox
  and may never become one; the separate table keeps the conversation schema
  honest.
- **Queue everything, silently** — turns the documented 429 into a slow 201
  for every existing client, and removes the upgrade lever entirely; #1026's
  argument against this is accepted.
- **Client-side retry guidance instead of a queue** — works for scripts,
  does nothing for the scheduled run that motivated this; the cron cannot
  retry itself.
- **Unbounded queue** — "accepted and never runs" is the worst of the three
  possible answers at the cap; both honest answers (wait briefly, or be
  refused) require the bound.
