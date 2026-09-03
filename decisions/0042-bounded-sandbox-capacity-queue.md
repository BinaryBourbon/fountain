---
type: ADR
title: "Bounded sandbox-capacity queue"
description: "Fresh starts can opt into a per-tenant FIFO queue at the tenant or fleet ceiling; scheduled runs always opt in, and ten requests wait at most one hour. Built with this ADR."
tags: [sandbox, quotas, api, schedules]
status: stable
adr: "0042"
adr_status: "Accepted"
date: 2026-09-03
generated: { by: codex/gpt-5, at: 2026-09-03T04:15:00-04:00 }
verified: { by: codex/gpt-5, at: 2026-09-03T04:15:00-04:00 }
stale_after: 2026-12-03
---

# 0042 — Bounded sandbox-capacity queue

**Status:** Accepted and built in the change that adds this file. Nothing
described here is unbuilt.

## Context

A start can reach two capacity limits. The tenant limit is funded by its
credit balance under ADR 0031. The fleet ceiling protects the deployment from
creating more provider sandboxes than it can run. The reservation returns
`sandbox_quota_exceeded` or `fleet_full` immediately at either ceiling.

Immediate refusal works for an interactive caller that can retry. It loses a
scheduled teammate run completely. A 09:00 firing that meets a fan-out at
08:59 records an error, and its next chance can be an hour away.

An unbounded queue would replace an honest refusal with work that can wait
forever. A queue also cannot weaken either capacity limit or the credit gate.
Several server replicas can receive slot-free events at the same time, so a
drainer must prevent two replicas from replaying one request.

## Decision

1. **Queued work has its own table.** `sandbox_requests` holds work before a
   sandbox or conversation exists. A `queued` conversation status would make
   a row with no sandbox leak into every conversation list, stream and client
   enum. Requests have `start` and `schedule_run` kinds. The first stores the
   original JSON-safe launch attributes. The second stores a schedule id and
   re-fires that schedule.

2. **Queueing is explicit for fresh API starts.** `queue: true` on
   `POST /api/conversations` changes a tenant-cap `429` or fleet-cap `503`
   into `202 Accepted` with the request and its position. Existing callers
   keep their immediate error. Starts with images do not queue because the
   server does not retain image bytes for an hour. Starts that explicitly
   name `sandbox_id` are attach or wake operations and also do not queue.
   Interactive prompt and wake paths keep their existing refusal behavior.

3. **Scheduled teammate runs always opt in.** A cron firing has nobody there
   to retry it. At either capacity ceiling, `run_schedule/2` creates one
   `schedule_run` request and writes `waiting for a free sandbox slot` on the
   schedule. An active request is deduplicated by schedule, so later firings
   do not stack while the first waits.

4. **The queue is bounded twice.** A tenant has at most ten active requests,
   configured by `SANDBOX_QUEUE_MAX_DEPTH`. A request waits for at most one
   hour, configured by `SANDBOX_QUEUE_MAX_WAIT_SECONDS`. At the depth bound,
   the original `429` or `503` is returned. At the wait bound, the request
   expires. The queue delays the cap; it never raises it.

5. **Capacity changes drive drains.** Every sandbox status transition goes
   through `Conversations.update_sandbox/2`. A transition out of `pending`,
   `starting` or `ready` can free both a tenant slot and the global fleet
   slot. It therefore pokes every tenant with active queue work. This remains
   true when several conversations share one sandbox: a conversation ending
   is not the trigger, but the sandbox leaving a cap-counting status is. A
   five-minute Oban cron is the lost-poke and expiry backstop.

6. **A drainer claims before replay.** The FIFO read orders by insertion time
   and id. A compare-and-swap moves one row from `queued` to `starting` before
   any conversation or schedule call. Only the replica that changed the row
   can replay it. Oban pokes are scheduled one second ahead and deduplicate
   only against another scheduled poke. A poke during an available, executing
   or completed job therefore creates a follow-up instead of disappearing in
   a uniqueness window. The five-minute backstop also returns a stale
   `starting` claim to `queued` if a worker died after the compare-and-swap.

7. **Every replay uses today's gates.** A start re-enters
   `start_or_resume_conversation/2`, including channel binding and the tenant,
   fleet, credit and platform-inference gates. A capacity error returns the
   claim to `queued` and stops that tenant's drain. Any other error is terminal
   and the next request can proceed. Reservation advisory locks remain the
   authority that makes capacity atomic.

8. **The resource is visible and leaves little data behind.**
   `GET /api/sandbox-queue` lists waiting work in position order, and
   `GET /api/sandbox-queue/:id` exposes its terminal outcome and conversation
   id. `DELETE /api/sandbox-queue/:id` cancels tenant-owned waiting work. Audit
   events cover enqueue, start, cancellation, expiry and failure. Telemetry
   reports queue status counts, tenant depth observations, outcomes and wait
   time. Every terminal transition erases `attrs`, including the prompt;
   provenance fields remain as small history rows.

## Consequences

- A scheduled run survives a temporary tenant or fleet capacity spike.
- A caller must handle a second success shape (`202` with a sandbox request)
  only when it opted in. The generated contract includes that shape.
- Freeing one fleet slot fans out one cheap Oban insert attempt per tenant
  with active work. Per-tenant scheduled-job uniqueness coalesces repeated
  transitions, and reservation locks decide which request wins capacity.
- A tenant can inspect position but not an estimated start time. Capacity
  release and run duration are not predictable enough for an honest estimate;
  wait-time telemetry supplies the data needed to revisit that choice.
- A request can fail after acceptance when its credit runs out, its agent or
  schedule disappears, its launch becomes invalid, or platform inference is
  unavailable. The terminal row and audit event state that outcome.

## Alternatives considered

- **Add `queued` to conversations.** Rejected because a request has no
  sandbox or conversation yet, and existing read models assume it does.
- **Drain only on a timer.** Rejected because an idle slot can then sit unused
  for five minutes. The timer is only a backstop.
- **Queue every wake and start.** Rejected because interactive callers already
  retry, and silently changing their response contract would be breaking.
- **Do not queue `fleet_full`.** Rejected because it is the same temporary
  capacity condition from the caller's perspective. A slot freed by another
  tenant must wake this request, which is why status transitions fan out.
- **Retain launch attributes on terminal rows.** Rejected because the prompt
  is tenant content and the audit trail needs only provenance and outcome.
