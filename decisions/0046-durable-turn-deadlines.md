---
type: ADR
title: "Durable turn deadlines and remote execution identity"
description: "Persist turn deadlines and provider-operation intent before I/O; the journal, its per-turn allowance and the deadline coordinator are implemented, while transport and lifecycle integration remain."
tags: [conversations, sandbox, reliability, limits]
status: draft
adr: "0046"
adr_status: "Proposed"
date: 2026-09-07
generated: { by: process:codex, at: 2026-09-07T22:39:25Z }
verified: { by: process:codex, at: 2026-09-07T22:39:25Z }
stale_after: 2026-09-21
---

# 0046 — Durable turn deadlines and remote execution identity

**Status:** Proposed; not shipped. `ExecutionGuard`, `TurnExecution` and their
migration are implemented locally. Full precommit passes: 4,632 tests and six
doctests, zero failures, two existing skips and seven exclusions. Thirty guard
regressions cover the journal. The existing
turn writer and ACP finisher preserve a registered deadline failure. Local
failure/interruption retains a remote-stop obligation; reset refuses unfinished
executions, and recovery marks lost termination owners uncertain without replay.
An obligation nothing can resolve ages out within two minutes, so neither state
fences a machine forever; an operator can also reap a stuck row from
`/admin/sandboxes` (#1768).
Host/account policy and typed-limit admission are built: the admission campaign
(#1787-#1793) shipped them on `main` before this ADR, and `turns.limit_reason`
publishes a bounded outcome. The request side of the public limit surface,
command transport, deadline scheduling, remaining lifecycle surfaces, SDK pins
and production acceptance remain unbuilt. No API or scheduler activates bounded
turns yet.

## Context

[Fountain #1732](https://github.com/BinaryBourbon/fountain/issues/1732) needs a
wall-clock bound that covers blocked tools. A timer in `ConversationServer`
cannot interrupt its blocked callback. Closing a local command transport does
not establish remote termination. A shared sandbox can host other conversations
([ADR 0023](0023-persistent-agent-sandbox.md)); deleting the machine is not a
per-turn cancellation mechanism. An ACP connection can also outlive its turn:
a stale timeout must not kill the process after a successor starts using it.

## Decision

Persist each bounded turn's absolute deadline and immutable tenant,
conversation, sandbox row/name/provider and connection identifiers. Record spawn
intent before opening the command transport. Bind the provider-issued session
ID from control metadata before sending the model prompt. Serialize completion
and expiration with conversation and journal row locks. An expired turn fails;
late completion cannot overwrite that outcome. Termination intent grants one
provider write outside the transaction. A lost reply preserves the fence and
cannot authorize a replay or replacement execution. Read the clock after taking
locks: waiting for a lock cannot extend spawn authorization beyond the deadline.

The deadline bounds the accepted turn outcome. An unconfirmed provider operation
may outlive it; this is not a guarantee of stopped billing or a strict dollar cap.
A local failure or interruption is not remote-exit evidence and retires its
connection through the termination journal before another turn may use it.

| Journal state | Meaning |
| --- | --- |
| `active` | Turn may proceed before its original deadline. |
| `awaiting_identity` | Work stopped locally; remote spawn identity is still unknown. |
| `ready` | Original session is known and requires termination. |
| `submitted` | One persisted attempt has been authorized; its result is outstanding. |
| `uncertain` | Result or ownership cannot be established; retain the fence until it ages out. |
| `stopped` | That attempt was confirmed, no spawn was ever submitted, or the obligation was written off. |
| `completed` | The turn ended; a positively identified connection may be reused. |

The journal retains identifiers and operation state independently of transcript
rows. Cascading deletion would erase uncertain provider intent. It stores no
prompts, credentials or provider response prose. Parent deletion or changed
ownership does not grant permission to terminate a replacement sandbox.
Audit events are recorded after transaction commit.

Reset and bounded registration share the existing per-sandbox advisory lock,
then lock parent/journal/turn rows. Reset refuses any open journal on the machine
and retires the sandbox row before provider I/O. The ordinary reset/wake path
creates a new row and name. Interrupted provisioning can reuse a name; it must
remain impossible to enter that path with an unresolved bounded execution.
Provider-issued incarnation checks and all recovery/reprovision paths still need
review before enabling termination in production.

### A fence is an obligation with an age, not a life sentence

`awaiting_identity` and `uncertain` are reached when the provider never named
the session, named two, or left a termination unacknowledged. Nothing moves
them on their own: a claim needs `ready`, and an acknowledgment needs the
`attempt_id` of an attempt whose owner is gone. Left alone they fence their
conversation and their machine for good, which costs the owner both recoveries
that exist for this — a new turn, and `reset_sandbox/2` (#1071). That is a worse
failure than the replay the fence prevents, so two bounded exits are part of the
decision rather than left to integration:

- **Age.** `_unsafe_retire_unresolved/2` retires a row that has sat in either
  state past a cutoff. It keeps `last_error`, so the trail still says the
  operation was never confirmed; it is written off, not erased. This authorizes
  no provider write — it gives one up. A session that really did survive is the
  `SandboxReaper`'s to find, the same as every unbounded turn's.
- **The operator.** #1768's reset fence answers the same question for a reset
  whose provider delete was never confirmed, and its answer is reaping from
  `/admin/sandboxes` — a terminal write still passes the fence, so an operator
  can always retire the row. ADR 0046 does **not** add a second lever for that.
  An earlier draft of this ADR proposed `reset_sandbox(force: true)`, a
  tenant-facing override; #1925 settled it against, because the age above
  already gives the tenant a bounded wait without new public surface, and two
  levers for one job is worse than one that is slightly slower.

`ExecutionDeadlineWorker` runs the first of these on its recovery tick; the
second needs no scheduler and ships with the journal.

A **retry** was the other candidate and is deliberately not what happens. The
journal's rule is that one persisted attempt authorizes exactly one provider
write, so re-arming a lost attempt would either replay an operation whose
outcome is unknown or require assuming `terminate_session/3` is idempotent
across a session that may already have been replaced. Ageing the obligation out
gives up a cleanup Fountain cannot confirm, which is a smaller claim than
either.

## Required integration and acceptance

- ~~Validate typed limits against runtime capabilities and host/account
  ceilings.~~ Done, mostly before this ADR: the admission campaign (#1787-#1793)
  shipped `ExecutionLimits`, `users.execution_limits` and `execution_allowances`
  on `main`, and admission refuses any control `enforced_controls/1` does not
  name — which today is all of them. The journal's share is
  `turn_executions.execution_limits`: the allowance a turn was admitted under,
  frozen on registration and checked against the absolute deadline by
  `enforce_deadline_ceiling!/3`. A caller that asks for a deadline beyond the
  allowance is refused rather than clamped. The column is written today and read
  by nothing: the reader that honours the frozen copy, so that a ceiling changed
  mid-turn neither narrows nor widens work already admitted, arrives with the
  command transport that gives a recovered turn something to resume. Each limit's
  per-turn or per-session scope, and the fact that SDK cost is estimated rather
  than billed, still need documenting for a reader.
- Record identity outside the conversation mailbox. Bind it to the command ref,
  original connection and turn; do not infer it from sandbox output or argv.
- Route every bounded turn start/end, autonomous turn, interruption and restart
  through the journal. Fence late database writes, stage events and warm reuse.
- Run deadline handling independently of the actor. Recover persisted intents
  without repeating unknown spawns or termination requests. Preserve partial
  usage and the original absolute deadline.
- Publish API/SDK/CLI documentation and prove timeout, restart, cancellation,
  neighboring-session isolation and actual cleanup through the public API.

Integration surfaces already inspected:

| Surface | Remaining work |
| --- | --- |
| `TurnMachine.open` and autonomous starts | Atomically reserve authorized limits and register before any provider work. |
| `ConversationServer.run_turn` and warm reuse | Preserve the deadline and connection identity; gate every prompt before writing it. |
| `TurnMachine.start_acp_peer` | Route the writer through a supervised transport that captures trusted session metadata outside the actor mailbox. |
| `ConversationServer.interrupt_turn` | Persist cancellation before blocking I/O; drive confirmed remote termination independently. |
| `wake_conversation`, `Rehydrator`, Horde starts | Honor open journal entries before reconnecting or replacing execution. |
| Interrupted provisioning and parent deletion | Preserve original ownership/incarnation and unresolved obligations through teardown or replacement. |
| Deadline supervisor | Coordinator, bounded pools, recovery and the ageing sweep are implemented (`ExecutionDeadlineWorker`), off unless `FOUNTAIN_EXECUTION_LIMITS` sets a ceiling. Durable stage-event delivery and public acceptance remain. |

Journal retention after confirmed cleanup and account deletion also needs an
explicit policy. Uncertainty must never be erased by transcript deletion — but
it must not be permanent either, which is what the ageing exit above settles.
The cutoff itself is the supervisor's to choose and is not fixed here.

### What the public surface does and does not yet promise

`turns.limit_reason` is on the API, the OpenAPI document and the wire contract,
because a client cannot otherwise tell a bounded failure from a plain one — a
runtime that answers after its deadline still exits zero, so `exit_code` alone
reads as success. It is output-only and additive.

The **request** side is deliberately not published yet. `enforced_controls/1`
returns `[]`, so every `execution_limits` a caller sends is refused; declaring
the field in the contract and shipping it in four SDKs and the CLI would
publish a control the server cannot honour, and an SDK version bump publishes
on merge. That surface belongs in the PR that first enforces a control, which
is also the PR that deletes this paragraph.

`managoat_sandbox 0.3.0` supplies confirmed remote termination. Provider identity
notifications await [Sprites #33](https://github.com/superfly/sprites-ex/pull/33),
tracked through release and exact pinning in
[Review Loop #109](https://github.com/managoat/review-loop/issues/109).
Do not activate deadline claims using an unpublished or floating SDK dependency.

## Validation scope

The database race proof in `decisions/evidence/turn-deadline-races.json` used separate
PostgreSQL connections: completion won 13 cases and expiry won 7. Every
expired case authorized exactly one of two competing termination claims. No
provider calls occurred. This proves database arbitration, not a running public
API deadline or provider cleanup. The lock-delay regression reproduced an incorrect spawn grant before the timing
fix. The final proof observed PostgreSQL lock waits on both parent and turn rows
before the deadline, then confirmed refusal after release. Neither delayed
request wrote a spawn intent.

Reproduce with `scripts/verify-turn-deadline-races.exs` through `MIX_ENV=test mix run`
after migrating a dedicated local database whose name starts with
`fountain_deadline_races_`. The script refuses other environments and leaves only
local fixtures; it cannot start provider workers.

## Alternatives considered

- Actor mailbox timers cannot enforce a deadline during a blocked callback.
- Silence thresholds interrupt legitimate long checks without bounding a turn.
- Local disconnects and signals alone do not confirm that remote work stopped.
- Reconstructing success from writable markers cannot recover trusted exit evidence.
- Replaying uncertain operations can create duplicate workers or affect a successor.
