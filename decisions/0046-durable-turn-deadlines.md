---
type: ADR
title: "Durable turn deadlines and remote execution identity"
description: "Persist turn deadlines and provider-operation intent before I/O; the journal, policy, coordinator and durable deadline events are implemented; transport and lifecycle integration remain incomplete."
tags: [conversations, sandbox, reliability, limits]
status: draft
adr: "0046"
adr_status: "Proposed"
date: 2026-09-07
generated: { by: process:codex, at: 2026-09-07T23:43:51Z }
verified: { by: process:codex, at: 2026-09-08T01:17:20Z }
stale_after: 2026-09-15
---

# 0046 — Durable turn deadlines and remote execution identity

**Status:** Proposed; not shipped. The journal foundation is in draft
[Fountain #1744](https://github.com/BinaryBourbon/fountain/pull/1744), with passing
CI at `f7404395b49019e4d122b91ba7991330b49addd3`.

The typed-policy layer is in draft
[Fountain #1745](https://github.com/BinaryBourbon/fountain/pull/1745), with passing
CI at `7db76444cb0abb987e4c3ad62d1b8aa18b29d254`: validated host/account ceilings,
conversation allowance narrowing, immutable journal snapshots, HTTP admission
checks, API stop reasons, and SDK/CLI request fields are implemented. All nonempty
effective limits are currently refused until released provider identity support and the complete lifecycle acceptance
gates pass. There is no user-configurable bypass of that gate.
Validation passes 4,663 tests and 6 doctests in full precommit, all four SDK suites
and contract checks, CLI tests/vet, and 20 separate-connection database races.
The typed-layer evidence and prior failures are recorded in
`decisions/evidence/typed-execution-limits.json`.
That branch also resolves ACP 0.4.0, Runtimes 0.4.1, Runner 0.2.2, and
Sandbox 0.3.0 from Hex; full precommit also passes on this set. The compatibility
releases, source bindings, and fresh-process check are recorded in
`decisions/evidence/execution-limit-dependencies.json`. The independent deadline
coordinator is now implemented locally and wired into application supervision.
It has separate expiration/termination pools, hard local task timeouts, bounded
shutdown draining, and recovery that never replays uncertain writes. Its 38
focused worker/journal tests and full precommit pass: 4,671 tests, 6 doctests,
zero failures. Evidence and corrected shutdown failures are recorded in
`decisions/evidence/execution-deadline-worker.json`. No deployment or production
timeout activation has occurred. The coordinator is now in draft
[Fountain #1746](https://github.com/BinaryBourbon/fountain/pull/1746), with passing
CI at `5e6eb3ecedce5e172a8cfad5ced1ae2bdb6c6943`.

## Context

[Fountain #1732](https://github.com/BinaryBourbon/fountain/issues/1732) needs a
wall-clock bound that covers blocked tools. A timer in `ConversationServer`
cannot interrupt its blocked callback. Closing a local command transport does
not establish remote termination. A shared sandbox can host other conversations
([ADR 0023](0023-persistent-agent-sandbox.md)); deleting the machine is not a
per-turn cancellation mechanism. An ACP connection can also outlive its turn:
a stale timeout must not affect a successor. Bounded turns use fresh connection
identities; successful replies still retire possible background work.

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
| `uncertain` | Result or ownership cannot be established; retain the fence. |
| `stopped` | That attempt was confirmed, or no spawn was ever submitted. |
| `completed` | Legacy journal state; new bounded connections are retired after every outcome. Reuse is refused. |

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

## Required integration and acceptance

- Typed validation and host/account narrowing are implemented locally. The
  admission capability set stays empty until the transport actually enforces
  the controls. Admission must check the selected sandbox provider as well as
  the runtime: Runner accepts Sandbox 0.3 but still refuses confirmed termination.
  SDK estimates remain separate from billed cost.
- Record identity outside the conversation mailbox. Bind it to the command ref,
  original connection and turn; do not infer it from sandbox output or argv.
- Route every bounded turn start/end, autonomous turn, interruption and restart
  through the journal. Fence late database writes, stage events and warm reuse.
- Run deadline handling independently of the actor. Keep expiration scans
  separate from the bounded termination pool, so blocked provider cleanup cannot
  consume all capacity for expiring other turns. Recover persisted intents
  without repeating unknown spawns or termination requests. Preserve partial
  usage and the original absolute deadline. The coordinator updates durable turn state independently. A further local
  branch commits the deadline stage and webhook/notification jobs with that
  state; full precommit passes 4,682 tests and 6 doctests.
- Publish API/SDK/CLI documentation and prove timeout, restart, cancellation,
  neighboring-session isolation and actual cleanup through the public API.

Integration surfaces already inspected:

| Surface | Remaining work |
| --- | --- |
| `TurnMachine.open` and autonomous starts | Local atomic admission/journal integration and autonomous refusal are implemented; 20 independent-connection admission races pass. |
| `ConversationServer.run_turn` and warm reuse | Local bounded turns use tracked setup and a fresh connection, including after credential refresh. |
| `TurnMachine.start_acp_peer` | Real actor tests use the supervised writer; released provider identity and live acceptance remain. |
| `ConversationServer.interrupt_turn` | Local public cancellation commits before contacting a blocked actor/provider. |
| `wake_conversation`, `Rehydrator`, Horde starts | Wake admission refuses open journals; a newly started actor retires old execution before provisioning/reattachment. |
| Interrupted provisioning and parent deletion | Deletion retains cleanup against the original sandbox; all sandbox transfer/reset/incarnation paths still require the final audit. |
| Deadline supervisor | Coordinator has passing draft CI; durable deadline-stage delivery passes local full validation. Public acceptance remains. |

The prepared transport branch retires every bounded connection after a reply,
including success. The turn can stay completed while its journal waits for
confirmed cleanup; a successor requires a fresh connection identity and a
cleared fence. Register before title generation,
adapter preparation, or any model prompt; keep cancellation intent ahead of
blocking provider writes.

Journal retention after confirmed cleanup and account deletion also needs an
explicit policy. Uncertainty must never be erased by transcript deletion.

`managoat_sandbox 0.3.0` supplies confirmed remote termination. Provider identity
notifications await [Sprites #33](https://github.com/superfly/sprites-ex/pull/33),
tracked through release and exact pinning in
[Review Loop #109](https://github.com/managoat/review-loop/issues/109).
Do not activate deadline claims using an unpublished or floating SDK dependency.

## Coordinator behavior

The coordinator scans due deadlines separately from known sessions awaiting
termination. Each pool admits at most eight tasks; a scan returns at most 100
candidates. A blocked termination cannot consume expiration slots. Task-local
10-second kill timers survive coordinator death. The provider call itself gets
5 seconds; neither local timeout proves that remote work stopped. Submitted
claims older than 60 seconds become uncertain, retaining their nonce and fence.
A normal coordinator shutdown gives tasks one second to finish journal writes,
then kills and awaits any remaining local tasks.

Tests start owned coordinators explicitly; normal test boot disables the child
to avoid scanning other tests' sandboxed fixtures. No public capability was
enabled by this change. All actor/lifecycle and trusted-identity requirements
above remain activation gates.

## Bounded command transport

A further local branch implements a supervised transport and guarded ACP writer.
The spawn intent is persisted before I/O. Provider control metadata must match
the returned command reference before the original connection can receive stdin;
stdout cannot supply identity. Every write rechecks the locked journal, ownership
and deadline. An in-flight write may become uncertain; it is never replayed, and
local task termination does not prove remote termination or stopped billing.

Close acknowledges persisted retirement intent, not remote confirmation. Owner
death also requests retirement. Failed local retirement writes retry; local tasks
have hard timeouts that survive coordinator death. Early frames have a bounded
buffer, and late identity can make an expired spawn cleanable. Local draining
ends 30 seconds after retirement (or the original deadline); remaining remote
uncertainty stays in the journal. Crash formatting redacts message and buffered
payloads. A terminal command frame seals local writes while the actor interprets
its outcome, so the transport cannot race a valid reply with an interruption.

The real ACP peer test completes a handshake and prompt through this writer,
observes Claude's typed SDK limit extension, then refuses a later prompt after
completion. These are local protocol tests with a simulated sandbox adapter;
there is no live provider or production enforcement proof yet. Focused validation
passes 66 transport/journal/event/coordinator tests. Full precommit passes 4,699
tests and 6 doctests with zero failures. Twenty independent-connection database
races also pass, including delayed spawn and stdin authorization after locks on
both parent and turn rows. See `decisions/evidence/execution-transport.json`.

The next local branch now selects this transport for an atomically admitted
bounded turn. `managoat_runtimes` 0.4.2 is published and consumed: its bootstrap
runs adapter installation and the final tagged/capability-cleared argv inside one
provider command. No pin or installer script is copied into Fountain. Initial
sandbox provisioning remains separate; this turn journal does not cover it.

## Actor lifecycle integration

The local integration commits the turn and journal together before turn setup.
It rechecks ownership, current limits, transport/runtime support and capacity;
failed registration rolls the turn back. SDK-only requests without a wall limit
are refused instead of receiving an invented deadline. Public capabilities remain
empty. Offline tests substitute that capability function explicitly; there is no
operator flag enabling the unfinished production path.

Bounded turns skip separate title inference, always use a fresh command, and
carry the journal through broker credential refresh. Their ACP writer receives
typed SDK options (Claude only); Codex wall deadlines preserve its capability
wrapper. A zero command exit without an ACP prompt reply is incomplete. Actor
messages recheck the journal, and independent retirement notifies an actor that
would otherwise wait silently on its peer. Completed bounded connections are
closed locally while the journal retains remote cleanup.

Public interruption commits retirement without waiting for the actor. Termination
and deletion also persist intent before teardown. A missing parent cannot erase
already committed retirement: cleanup still requires the original sandbox row's
tenant/name/provider binding. A changed or missing sandbox identity stays
uncertain. A surviving parent must still have its original tenant/sandbox binding.
An active journal whose turn vanished without retirement remains uncertain.

Wake admission refuses unresolved execution. A new actor retires a prior journal
before provisioning or reattachment; it does not replay an unknown spawn. An old
unbounded connection cannot open an autonomous turn after bounded policy applies.

Seventeen lifecycle regressions cover real actor launch/SDK options, completion,
early exit, cancellation with a blocked actor, silent-peer deadlines, restart
retirement, parent deletion, changed sandbox identity and lifecycle timer
preservation. Fresh launch lives in `TurnLaunch`; `ConversationServer` shrinks
from its 2,767-line pin to 2,706. Its size regression also passes.

`scripts/verify-bounded-lifecycle-races.exs` uses independent connections in a
dedicated local PostgreSQL database. Twenty admission races each commit one turn
and journal. Twenty cancellation/spawn-intent races preserve uncertainty rather
than replay; twenty parent-deletion/cleanup-claim races retain original cleanup
authority. Provider acknowledgments are synthetic fixtures, and no provider I/O
occurs. The original twenty completion/deadline races also pass.

Full precommit passes **4,716 tests and 6 doctests, zero failures** after the
size-gate extraction. Evidence and prior corrected failures are recorded in
`decisions/evidence/bounded-lifecycle.json`. Late write atomicity, every sandbox
lifecycle path and live provider acceptance remain activation gates. The released Sprites identity
change is still required. These tests do not prove actual termination, escaped
process cleanup, aggregate budgets or stopped billing.

## Transcript and accounting fences

The follow-on transcript layer serializes bounded output and turn-tagged model
stages with retirement. It reads the clock after acquiring the parent, journal
and turn locks. Rejected output creates neither a row nor a PubSub/sidebar
notification. Turn stages now retain their explicit turn foreign key. A terminal
stage must agree with the persisted turn outcome; deadline events retain their
existing durable identity and delivery path.

A retired turn refuses stale changes to its prompt, reply, model selection and
permission state. The winning terminal update may retain its exit code. Delayed
usage uses a separate parent-before-turn transaction: only the first committed
report increments conversation totals, including when the caller holds a stale
Turn struct. This preserves submitted accounting after retirement without
asserting that a disconnected provider can always deliver its final usage.

Full precommit passes **4,728 tests and 6 doctests, zero failures**. The focused
suite passes 90 tests, including twelve new regressions. Sixty new independent
PostgreSQL races cover duplicate usage, usage/cancellation and output/cancellation;
four delayed-lock cases cover actual output/model writers. Twenty earlier
deadline races also pass. All twenty output/cancellation races observed
cancellation first; the separate active-output regression verifies accepted
writes. The analytics fixture correction and validation hashes are retained in
`decisions/evidence/bounded-transcript.json`. No provider I/O occurred in these
new proofs.

This layer still does not fence every conversation/session metadata mutation or
untagged lifecycle event. Sandbox transfer, parking, replacement and incarnation
safety remain separate activation gates. Public controls remain disabled.

## Parent generations and recovery

The next prepared layer fixes a reproduced stale callback: after cancellation
and successor admission, the old `TurnMachine.finish` could still mark the parent
idle while the successor's turn and journal remained running. Parent writes now
lock the parent, journal and turn, check the latest turn, and read the deadline
after the locks. Ended turns cannot revive failed or terminated parents.

Session reports, session preparation, lost-session reports and pre-start failures
use the same generation check. Actor session state changes only when persistence
was accepted. A legacy idle peer may clear only its unchanged session with no
running turn or bounded execution history. Explicit wake/provisioning session
resets remain part of the pending sandbox lifecycle audit.

Admission commits running parent status with the turn and optional journal;
launch no longer writes through a stale parent snapshot. Autonomous admission
also commits status before usage records and sidebar notifications. Failed
admission rolls the change back, and terminated/failed parents refuse admission.

Orphan recovery now takes parent/journal/turn locks in the same order as
cancellation and usage. It retires execution before recovery writes, preserves
unknown spawn intent and deadline outcomes, and cannot idle a successor. The
unknown end is marked `orphaned_at`; it is not provider-exit or billing evidence.
A changed original binding refuses recovery. Audits and sidebar notifications
remain after commit.

Two real-actor tests stop callbacks after dispatch but before persistence, then
cancel and admit a successor. Completion and session callbacks cannot alter that
successor. Provider cleanup acknowledgments in those tests are synthetic. Public
controls remain disabled pending sandbox transfer/park/reset/incarnation safety,
released provider identity support and live acceptance.

Full precommit passes **4,755 tests and 6 doctests, zero failures**. The focused
suite passes 138 tests, including 27 new regressions. Eighty new independent
PostgreSQL races cover parent idling/admission, session/cancellation, recovery/usage
and recovery/cancellation. Four delayed-lock cases exercise session and recovery
writers; twenty earlier deadline races also pass. No provider operations occur.
Observed race schedules, source/log hashes and corrected validation failures are
recorded in `decisions/evidence/turn-parent-fences.json`. The final full gate also
verifies the explicit legacy webhook call restored after the catalogue check
caught its loss from the source scanner; event names and assertions are unchanged.

## Durable release refusal

Release now checks persisted running turns and unfinished execution journals
under the parent lock, including when its actor is absent or locally idle.
Refusal returns `busy` without changing the parent, interrupting the turn,
closing the actor's connection, revoking its callback credential or publishing a
release event. The actor closes only after the parent transaction commits.
Admission shares that lock and cannot revive a released parent.

Confirmed cleanup permits release; unknown spawn, pending termination and
uncertain termination remain busy. Releasing one idle conversation leaves its
sandbox and unrelated active co-tenants untouched. This preserves release's
busy-without-interruption contract. It is not a machine-wide park, transfer or
destruction fence; those paths and provider incarnation remain activation gates.

Full precommit passes **4,765 tests and 6 doctests, zero failures**. The focused
suite passes 103 tests, including ten new regressions and one real-actor refusal.
Sixty independent PostgreSQL races cover release against admission, orphan
recovery and cleanup acknowledgment; twenty earlier deadline races also pass.
Identities and acknowledgments are synthetic. Evidence, observed schedules and
the corrected association-loading fixture comparisons are retained in
`decisions/evidence/release-fence.json`. No provider operations occurred.

The parent PR's separate CI dependency audit is red: the EEF feed for
CVE-2026-32686 currently includes Decimal 3.1.1, while the maintainer advisory
identifies 3.0.0 as patched. This discrepancy remains unresolved; the audit has
not been waived. Local precommit does not run that separate CI gate.

## Durable deadline events

The prepared event layer passes full precommit: 4,682 tests and 6 doctests,
zero failures. Its 74 focused tests include 11 event regressions. Twenty
separate-connection races passed: completion won 13 and expiry won 7; every
expired case reused one event across two competing late publishers. No provider
operations occurred. See `decisions/evidence/deadline-events.json`.

The event layer stores one failed `turn` log event in the expiration
transaction, including `turn_id` and `wall_time_limit`. That transaction also
queues matching tenant webhook deliveries and a retryable local notification.
No PubSub or provider write occurs before commit. A database failure rolls back
the turn, event and jobs together. Webhook delivery keeps its existing retry
policy; this does not guarantee that a receiver will accept it.

Terminal stage publication takes the same journal locks. A late successful
reply or interruption reuses the committed deadline event. Its immutable id
remains in the journal after transcript retention, so deletion cannot authorize
a contradictory replacement. Missing parents or changed tenant ownership do
not grant notification authority.

Local notification uses the existing webhook queue and retries with the same
log id. Streams, webhook delivery and notification-derived telemetry are
at-least-once; notification counts are not distinct turn counts. A replay does
not enqueue more webhook jobs. Malformed retained metadata cannot prevent the
committed stage from reaching local subscribers. HTTP delivery and provider
termination remain independent operations.

The deadline-event layer alone fences terminal deadline events. The later
lifecycle and transcript sections describe additional integration; the remaining
activation gates still apply.

## Validation scope

The parent journal proof at `f740439` in `decisions/evidence/turn-deadline-races.json` used separate
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

## Sandbox admission and identity preparation

All user and autonomous turn admissions now take the machine lock before the
parent lock and require a ready sandbox owned by that parent. This includes
unlimited turns: a reset that retires the machine prevents either source from
starting work, and an admitted turn makes reset refuse with `sandbox_mid_turn`.

`SandboxIdentity` can record a provider ID from control metadata. The first
binding is immutable through this interface, survives row retirement, and emits
one audit event. General sandbox attributes cannot set it. Provider lookup runs
before the binding transaction, which rechecks the observed owner, provider and
name. Conflicting identities and stale or retired rows are refused.

Sandbox status writes now lock and re-read the persisted row. A callback holding
an old `starting` or `ready` struct cannot revive a `failed` or `terminated`
sandbox. Usage transitions use the persisted previous status. A real actor test
pauses setup, retires the sandbox, then releases setup and verifies the actor
stops without publishing a ready row. This does not establish remote cleanup or
correct retention of uncertain provider spend; those still need the operation
journal below.

Sandbox 0.4.1, Runner 0.2.3 and Runtimes 0.4.3 are released and locked here.
Sandbox's optional `create_new` refuses conflicts and returns provider identity
on confirmed creation; ordinary `create` retains its adoption behavior. The
ordinary provisioning path retains `create`. Bounded conversations now use the
operation journal and `create_new`; public execution controls remain disabled.

`SandboxOperations` commits fresh-create intent before provider I/O and keeps
historical ownership, the original interval start, and capacity after parent
deletion. Conflicts cannot adopt an existing name. Readiness binds only the
confirmed fresh response, after checking the parent and machine again. Cleanup
call sites route managed claims through a durable delete intent. Uncertain
results block another service call and retain capacity and potential provider
time; they do not prove actual cost. Legacy suspend events cannot discount these
managed intervals.

Managed cleanup now uses Sandbox 0.4.1's `destroy_once`: one DELETE and at most
one GET, sharing a deadline with retries and redirects disabled. Only a 404
confirms absence. HTTP acceptance alone retains uncertainty.

**Integration is incomplete.**
The journal's permanent name claim prevents another managed create from adopting
it; ordinary legacy creation is not yet covered by that registry. Recording a
GET response does not authorize a later name-based DELETE or prove an uncertain
create belongs to this row. Full holder arbitration and live provider acceptance
remain required. Managed park/resume now use the same durable operation journal,
as described below; ordinary legacy creation still has a separate lifecycle.

`SandboxOperationWorker` now scans up to 100 candidates per category, with
separate four-task pools for cleanup and observation. Submissions older than
three minutes become uncertain without another provider call. Recovery claims
are throttled for a minute under a row lock. Each task has a 35-second local
timeout that survives coordinator failure; a blocked provider cannot stop the
separate submission-recovery task.

Confirmed creates whose parent records disappear or whose accounts are deleted
retain cleanup authority through the journal. Ownership and provider identity
are checked again before I/O and before recording an observed deletion.
Recovery rechecks current holders; a live persistent home is not reclaimed merely
because its original conversation disappeared. An uncertain delete can be settled
by a read confirming absence. An uncertain create is never
probed or released from a missing-name observation: its original request could
still finish later.

The recovery worker is **disabled by default** through
`:sandbox_operation_worker_enabled`. Activation remains outstanding. Provider
reads use the existing adapter under the task timeout; this does not establish
aggregate inference limits or dollar-cost accounting. No live cleanup is claimed.

## Managed park and resume

`SandboxTransitions` commits a park or resume grant under the machine lock,
then contacts the provider outside the transaction. The grant closes turn
admission and retains physical capacity. Both user and autonomous turns check
pending operations. Reset and managed cleanup refuse conflicting transitions.
A stale ready write cannot bypass the operation fence.

The actor and reaper use this path for managed machines. A refusal keeps the
actor's connection and does not report successful retirement. Home checkpoints
use the released Sandbox 0.4.2 `create_checkpoint_once/2` contract. The durable
operation ID binds one creation request to one exact-comment confirmation; an
older checkpoint cannot substitute. Disabled checkpoints are skipped. An
unconfirmed result retains the fence without publishing park success or granting
a retry. Metadata is written only after transition confirmation. Sprites suspend
is a no-op: logical parking does not establish stopped compute or billing.

Managed resume and ready reuse require the provider response to contain the
recorded instance ID. Presence under the same name is insufficient. Resume
retains the existing capacity reservation rather than acquiring a second slot;
its provider request runs outside the quota transaction. The response is checked
against current ownership, operation generation and retirement state before
readiness is accepted. Provider tasks have a 35-second ceiling that survives
caller death. Outer transactions are refused before provider work starts.
The released checkpoint adapter shares a 30-second deadline and 65,536-byte
response budget across creation and confirmation, with retries and redirects
disabled. SDK socket tests verify local transport closure on timeout, oversized
responses and caller loss. This does not undo a submitted remote checkpoint or
prove conditional provider-instance writes. Fountain integration tests exercise
the released adapter against a simulated HTTP provider; live acceptance remains
outstanding. See `decisions/evidence/sandbox-checkpoint-integration.json`.

Park events, webhook jobs and local notification jobs commit with the transition.
The existing persisted-stage notification worker delivers them after commit.
Co-tenant park messages carry the operation generation; an old message cannot
stop an actor on a resumed machine.
Best-effort audits run in the executing park/resume entry points after the
journal transaction commits. Successful grant and completion transactions retain
only durable transition, stage and notification writes. A regression forces real
PostgreSQL audit insert failures and verifies that park, resume, capacity and stage records remain
intact.

Unknown transition outcomes remain fenced, without an automatic replay.
Actor startup/shutdown versus concurrent wake, destructive lifecycle-bound rechecks,
recovery of uncertain park/resume outcomes, ordinary creation name coverage and
live provider acceptance remain unfinished. Execution controls and the recovery
worker remain disabled. These source changes do not activate production cleanup.

## Holder arbitration

`SandboxHolders` now serializes conversation creation, updates and replacement
with the same machine locks as turn admission and cleanup. Two-machine transfers
lock the numeric advisory keys in sorted order, then re-read parent ownership.
A stale update cannot overwrite a newer binding. Destination identity, runtime,
credential isolation and unresolved provider operations are checked under those
locks. Active turns and unresolved executions prevent a holder transfer.

A fresh pending machine can accept its first conversation. Ready and suspended
machines retain their supported attachment path. Legacy Team machines without
disk-identity columns may reuse only unanimous, locked historical lineage; any
provider-operation record disqualifies that fallback. This does not adopt a
provider machine by name or resolve an uncertain create.

Replacement moves its initiating conversation and current live co-tenants in one
transaction. A refusal leaves every binding unchanged. A co-tenant's separate
winning transfer is preserved. Replacement stages, webhooks and local notification
jobs commit with the move. Delivery checks the recorded owner; a delayed message
can close only an actor still on the original machine whose conversation now
names that replacement. Newer actors and bindings ignore it.

Autonomous admission now requires the actor's original sandbox ID through
`Connection.open_autonomous_turn/3` and the journal guard. A stale actor cannot
record an autonomous turn against its conversation's new machine. This is an
admission guarantee, not evidence that an already-started remote background
operation stopped.

`scripts/verify-sandbox-holder-races.exs` exercises real contexts on independent
local PostgreSQL connections, including both forced lock orders, reciprocal
transfers and bulk replacement versus an individual move. It also reruns the
existing deadline, reset/admission and park/resume arbitration suites. See
`decisions/evidence/sandbox-holders.json` for exact scope and results.

Actor startup versus the durable replacement claim and queued-prompt preservation
remain integration gates. These database changes do not complete wake recovery or
enable the recovery worker or execution controls.

`scripts/verify-sandbox-admission-races.exs` exercises real reset and admission
contexts through separate local PostgreSQL connections, with outbound deletion
stubbed. It covers both turn sources, forces both lock orderings and races two
identity bindings. It also races retirement against late ready callbacks and
forces the callback to wait for the retirement transaction. This proves database
arbitration only; no provider operation
or production deployment is claimed.
The retirement regressions, release pins and preserved failed-run evidence are in
`decisions/evidence/sandbox-retirement.json`.

## Alternatives considered

- Actor mailbox timers cannot enforce a deadline during a blocked callback.
- Silence thresholds interrupt legitimate long checks without bounding a turn.
- Local disconnects and signals alone do not confirm that remote work stopped.
- Reconstructing success from writable markers cannot recover trusted exit evidence.
- Replaying uncertain operations can create duplicate workers or affect a successor.

## Managed park eligibility

A managed park grant now rechecks its requested idle or lifetime reason after
locking the machine, current parents, creation and sandbox row. It reads the
current policy and clock there. A stale verdict creates no operation, sends no
provider request and leaves the actor connection intact. Resume has no idle
requirement. Busy turns and unresolved execution still refuse parking.

`SandboxActivity` uses turn insertion, start and completion times across current
holders, plus machine creation, last wake and holder attachment. Attachment,
transfer, revival and replacement stamp `last_attached_at` in their transaction.
This internal column is absent from the caller-controlled changeset. Parent
creation times cover legacy rows without an attachment clock. Ordinary title,
status and provider bookkeeping do not extend the idle grace period. The
continuous-run ceiling still starts at creation or the last wake.

The managed reaper uses the same activity calculation as a selection hint. The
grant remains authoritative after waiting for locks. Legacy unjournaled paths
retain their previous behavior. Destructive lifecycle grants still need their
own bound recheck; this park change does not authorize their activation.

`scripts/verify-sandbox-idle-races.exs` forces PostgreSQL lock waits while idle
policy is disabled, extended or tightened, a long turn completes, a holder
attaches, or the machine wakes. It also reruns the holder and transition proofs.
A winning fresh attachment now prevents idle parking. Evidence is recorded in
`decisions/evidence/sandbox-idle.json`. Actor wake coordination, uncertain
transition recovery and live acceptance remain gates; the stack stays draft and
execution controls and recovery stay disabled.
