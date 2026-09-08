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
creates a new row and name. Interrupted provisioning stays fenced; its helper
cannot destroy and recreate the machine or bypass an unresolved execution.
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
Actor startup/shutdown versus concurrent wake,
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
retain their previous behavior. Bound-driven deletion now has its own locked eligibility check, described below.
Neither path is approved for production activation yet.

`scripts/verify-sandbox-idle-races.exs` forces PostgreSQL lock waits while idle
policy is disabled, extended or tightened, a long turn completes, a holder
attaches, or the machine wakes. It also reruns the holder and transition proofs.
A winning fresh attachment now prevents idle parking. Evidence is recorded in
`decisions/evidence/sandbox-idle.json`. Actor wake coordination, uncertain
transition recovery and live acceptance remain gates; the stack stays draft and
execution controls and recovery stay disabled.

## Bound-driven deletion

The managed actor and reaper use a dedicated deletion entry point for lifecycle
bounds. Its grant requires a current ready machine, current policy and the
matching continuous-run deadline after machine, parent and identity locks. A
running turn or unresolved execution still refuses deletion. Explicit owned
termination and retired-holder recovery keep their separate eligibility rules.

The current machine mode also determines the action. Managed Sprites machines
park when idle. At the maximum lifetime, persistent homes park and ephemeral
machines may be deleted. The reaper now parks managed homes at that ceiling.
A stale mode cannot downgrade deletion to parking, delete a current home, or
skip a current home's checkpoint. Recent completion and attachment refresh idle
activity; they do not reset the continuous-run lifetime clock. A wake does.

Bound execution refuses an outer transaction. Its composable grant has no audit
side effects; execution audits only after the grant commits. Audit insert
failures cannot undo an accepted deletion. Uncertain provider replies retain the
reservation and do not authorize replay.

`scripts/verify-sandbox-destroy-bound-races.exs` forces eight PostgreSQL lock waits
covering changed policy, mode, wake and admission, and reruns the preceding
proofs. `decisions/evidence/sandbox-destroy-bound.json` records the validation.
These are local database and adapter tests. Legacy unjournaled behavior, durable
wake ownership, actor shutdown/publication coordination, uncertain-transition
recovery and live acceptance remain integration work. Execution controls and
recovery stay disabled; the lifecycle stack stays draft.


## Provisioning ownership

Fresh wake now commits its replacement binding and launch before Horde startup,
as described below. The earlier five-second binding wait remains only for stored
legacy child specifications. A changed binding or owner stops those children.
A real actor test holds the startup reply and verifies that credentials and
receipt delivery observe the already committed replacement.

Actor startup now checks its original machine binding under the machine and
parent locks before it can interrupt an orphan execution. A child stored by
Horde for an old machine stops before provisioning or credential loading when
the parent has moved. Explicit user cancellation keeps its existing behavior.

The provisioning watchdog watches the original PID. Its timeout locks the
original machine and current parent, then rechecks ownership, provisioning
status and active execution. A moved parent receives no stale failure. An
accepted timeout commits the failed rows, stage and delivery jobs together
before terminating the old PID. Unknown creation keeps its journal and capacity;
a timeout does not authorize another provider call. Database errors retry the
same timeout decision without restarting provisioning.

The actor regressions cover a stale child with a running replacement and a
blocked old actor whose parent moves. The watchdog tests cover transactional
notifications, ownership drift, settled machines, cotenant execution and uncertain
creation. `scripts/verify-provision-ownership-races.exs` forces transfer and new
execution admission to commit while startup and watchdog decisions wait on
independent PostgreSQL connections. Validation is recorded in
`decisions/evidence/provision-ownership.json` for the earlier checkpoint and
`decisions/evidence/prompt-delivery.json` for the receipt integration.

Binding protection now includes the process claims described below. Ordinary
provisioning failures use a scoped outcome transaction. Database-first fresh
replacement is now implemented below. Abandoned-claim and complete accepted-prompt
recovery remain unfinished; local validation is not live provider acceptance. The lifecycle stack stays draft; execution
controls and recovery stay disabled.

## Durable prompt delivery (integration in progress)

Prompt submission, initial creation, attach and wake-with-text now use durable
receipts. Opening intent commits before Horde can start its worker. Initial and
attach launches reject outer transactions, and invalid opening input is refused
before any sandbox reservation. These changes have not passed production acceptance.

A submission stores its pending turn, ordered images, receipt and dispatch job in
one transaction.
The receipt keeps hashes of the idempotency key and complete payload; it duplicates
no prompt, image bytes or raw key. Keys are scoped to the owned conversation. A
changed payload under the same key is a conflict. The receipt survives transcript
retention, so deleting a turn cannot make an old key authorize another admission.
Older pending turns without receipts are not dispatched.

Activation changes the saved turn to running and claims its receipt under machine,
parent, receipt and turn locks. Any bounded execution journal commits in the same
transaction. Runtime capacity is resolved under the admission locks. The executing
wrapper refuses an outer transaction; usage follows commit. A claim grants one
admission and is never reset. It does not prove that a provider received a prompt,
nor does it permit replay after a lost acknowledgment.

Actors can discover queued receipts after provisioning or reattachment. Messages
carry only receipt IDs, and duplicate messages cannot create a second turn. Images
are loaded from the saved turn and are not inserted again. An admission refusal
persists a failed turn and delivery jobs together. Actor refusals recheck the
original machine binding, so an old busy actor cannot fail a replacement's request.
Actor-start failure and provisioning deadlines also refuse queued receipts inside
the transaction that records the original machine's failure. A changed binding
suppresses that failure. Legacy turn admission cannot insert a new turn while a
receipt is queued or a user turn is running. Receipt activation updates the saved turn.

The dispatch job retries ID notifications every 15 seconds until the receipt is
claimed or refused. A cast does not count as delivery. Acceptance snapshots a
35-minute deadline, allowing the ordinary 30-minute provisioning budget plus
notification time. Hosts can set a positive `:prompt_delivery_timeout_ms`; changes
do not extend saved receipts. Expiry fails only an unclaimed turn and commits its
failure event and notification jobs together. Activation checks the saved deadline
after acquiring its row locks. Expiry does not retire a machine, clear an uncertain
provider operation or authorize another attempt. Dispatch may now claim a saved, unstarted prompt wake; it cannot replay a started
invocation. Complete actor recovery remains an integration gate.
`PromptDispatchSweep` revisits queued receipts each minute through the same dispatch
boundary, recovering notifications whose original jobs crashed, were discarded or
were removed. It leaves existing jobs unchanged. Pages contain at most 100 receipts;
the next page is committed before dispatch begins. Each page has a 30-second job
timeout, and ordinary per-receipt failures do not skip later receipts.

The prompt API returns the receipt ID, turn ID, deadline and saved state. Reusing an
`Idempotency-Key` with another payload returns HTTP 409. The shared accepting wrapper
refuses outer transactions, saves intent, then notifies an existing actor or initiates
one wake for a new receipt. Replaying a key never repeats wake. A missing agent during
wake records refusal; uncertain delivery retains queued intent until expiry. A
pending sandbox's registry timeout now returns `:provisioning` and retains its
binding and capacity instead of provisioning a replacement. Durable prompt wake
requests now cover submitter death before initiating wake, as described below.

User interruption cancels queued receipts under the same parent lock as execution
retirement. Startup retirement preserves them for delivery. A queued receipt also
prevents releasing the conversation's machine. Claimed work follows the existing
execution cancellation path and is never reset to queued.

The local tests cover actor startup after a lost notification, duplicate delivery,
retention, tenant scope, policy changes and transaction rollback.
`scripts/verify-prompt-receipt-races.exs` exercises duplicate submissions, duplicate
claims, distinct requests, user interruption and duplicate expiry against
activation on independent PostgreSQL connections. It also forces activation to wait
past its deadline on parent, receipt and turn locks. It also races legacy admission
against receipt activation, and actor-start failure against watchdog expiry. These
local database checks do not prove live provider behavior.

Still required: safe actor recovery after a lost startup and complete
restart/cancellation coverage through the actual entry points. Legacy raw actor callbacks remain for compatibility;
current launch paths send receipt IDs. Abandoned-actor and uncertain-provider
recovery remain separate integration gates. Local validation does not authorize
production activation.

### Opening image validation

Opening images require nonblank prompt text. The previous creation path returned
201 without storing or delivering images when text was absent. Creation now
returns 422 before reserving a sandbox. Media-type tests include prompt text;
the HTTP regression checks both the refusal and persistence before actor start.

## Owned provisioning outcomes (integration in progress)

A late setup callback previously released every broker session for its conversation,
including a replacement worker's session. Helper stages also published through the
conversation ID after its machine binding changed. A real actor regression reproduces
the release bug; the existing parent update guard already rejected the stale row update.

`ProvisionContext` snapshots the tenant, conversation, original machine and fresh or
reattach phase. It locks the original machine and parent before saving setup output,
stages or failure. Both tenant IDs and the current binding must still match.
A transfer that commits first suppresses the old callback's output and outcome.

An accepted failure commits the parent failure, queued-prompt refusal, stage events,
notification jobs and revocation of only the worker's saved broker token together.
Fresh provisioning fails its pending or starting machine before provider cleanup;
a ready machine or active execution refuses that decision. Reattach failure leaves
the machine and cotenant turns intact. An already retired original machine permits
settling only its still-pending parent, without granting another cleanup operation.
A reset idle conversation and its new prompt remain protected.

A failed outcome transaction keeps the actor alive and retries the same decision.
The actor test injects a failed webhook enqueue: the receipt stays queued, no second
machine is created, and cleanup occurs once after persistence recovers. Native broker
session minting and its stages now share the binding transaction too, so a failed
notification enqueue cannot leave an unreturned live token. Stage notifications use
the durable delivery job; saved output remains available through event reads.

`scripts/verify-provision-context-races.exs` forces stage, output, failure and broker
mint operations to wait behind a real transfer on separate PostgreSQL connections.
The actor test also resumes the actual setup-script helper after replacement admission
and checks that its output and failure cannot affect the running replacement.
Validation is recorded in `decisions/evidence/provision-context.json`.

This does not establish safe recovery of a lost actor or conditional provider
deletion. The startup claims below add same-machine arbitration. Cleanup still uses the existing sandbox-operation
path after the failure commits; unmanaged provider identity and uncertain operation
recovery remain integration gates. The lifecycle stack stays draft and disabled
pending those checks and live acceptance.

## Actor startup claims (recovery integration in progress)

A real duplicate-start regression showed a second actor destroying and recreating
its live predecessor's provisioning machine. Horde registration alone did not
prevent the second callback from treating `starting` as an interrupted attempt.

Each process now acquires a durable claim before credentials, startup interruption
or provider work. The database allows one active claim per conversation. Its ID,
tenant and original machine are immutable; a retired ID cannot become active again.
Repeated delivery of the same claim is idempotent. A different incarnation on the
same machine is refused while the existing claim is active.

A committed holder transfer can supersede the old machine's claim. Provisioning
stages, output, failures, broker minting, startup interruption and watchdogs carry
the process claim and recheck it under the original machine and parent locks.
A predecessor watchdog cannot fail a successor on the same machine. An unclaimed
duplicate exits before credentials and cannot clear its predecessor's redaction state.

Completed actor teardown releases only its own claim. Teardown and successor
claims serialize on the parent lock, including when the machine stays the same.
Stages produced within that transaction save their webhook and notification jobs
before commit; rollback emits no stage. Orphan-turn analytics and sidebar refresh
follow the committed notification. A clean shutdown permits reattach without
creating another machine.

Claims have no time-based takeover. An untrappable process or node failure retains
its active claim; registry absence cannot authorize another provider attempt.
Recovery still needs to distinguish an unstarted request from submitted or uncertain
operations before reconciling that claim and starting another actor. This behavior
is an integration boundary, not completed crash recovery. The lifecycle stack stays
draft and must not be deployed until recovery and live acceptance are proved.

The actor tests cover duplicate provisioning, preservation of a running bounded
execution, clean shutdown/reattach, and redaction ownership. Independent PostgreSQL
connections exercise competing claims and both orders of same-machine handoff
versus predecessor publication in `scripts/verify-actor-ownership-races.exs`.


## Durable prompt wake handoff (recovery integration in progress)

A regression kills the accepting process after its receipt and dispatch job commit,
before it reaches worker discovery. Previously the saved job only notified existing
actors, so the prompt expired without a wake. Acceptance now commits a wake request
with the receipt, turn, images and job. Low-level submission and opening-prompt
storage do not implicitly authorize wake; their creation paths still own startup.

The caller, dispatch job and minute sweep share the same handoff. An existing actor
receives the receipt ID. Otherwise the handoff locks the original machine, parent,
receipt and wake request, verifies tenant and binding, and checks cancellation and
the original delivery deadline. Exactly one caller changes `requested` to `started`
before entering the existing wake policy outside the transaction. Identity and
invocation timestamps are immutable. Repeated keys and notifications cannot restart
that invocation, including when its response is lost.

Wake receives the saved parent binding and refuses a changed tenant or machine.
The existing account, inference, provider and actor-ownership gates still apply.
Return records `returned`; this means the function returned, not that a provider
operation succeeded. Missing-agent refusal commits with that return marker.
An exception or process death leaves `started`, which also fences wakes from newer
receipts on that conversation. A settled reconnect request can establish handoff
as described below. Registry absence or age cannot release that fence.

This closes the pre-invocation submitter gap. It does not recover a process lost
after the invocation claim or establish a provider incarnation. Fresh creation
and fresh replacement now have the durable launch protocol described below.
Ready-machine startup now uses the reconnect protocol below. Suspended-provider
wake and abandoned-actor recovery still need integration and provider journal links. A stopped actor claim
on a still-starting machine also needs reconciliation before any new creation.
These are remaining integration gates, not reasons to deploy the current draft.


## Unresolved provisioning after shutdown

A real actor regression confirmed that a failed provisioning decision could roll
back while the provider machine survived. Shutdown then marked its actor claim
`stopped`; a successor treated the still-`starting` row as permission to destroy
and recreate that machine. Local teardown had established no remote outcome.

New startup claims now refuse `starting` machines, including legacy rows without
claim history. A `pending` machine with any previous actor claim also requires
reconciliation, even if that claim stopped, was superseded, or belonged to another
conversation. The original machine lock serializes this check across parents.
Rejected target startup cannot supersede an existing claim. Retired IDs remain
retired, and an existing incarnation may still read its own active claim.

Startup returns the parent and machine read under its claim lock. It cannot
choose fresh provisioning using an earlier `pending` snapshot after the locked
row became ready. Ready machines retain the ordinary reattach path. The legacy
interrupted-attempt helper now refuses instead of destroying and rebuilding.

This prevents unproved recreation; it does not implement recovery. Fresh creation
now records launch provenance as described below. Ordinary provider identity,
stopped/abandoned claim reconciliation and ready-machine wake recovery remain incomplete.
Legacy in-flight machines require reconciliation at rollout. Keep this stack
draft until that path and live acceptance are demonstrated.


## Atomic creation and durable actor launch (integration in progress)

Fresh creation previously committed its sandbox and parent before its opening
prompt. Creator death could leave a partial reservation or a saved prompt with
no durable startup path. Fresh creation now commits the sandbox reservation,
parent, optional prompt receipt and launch request with its dispatch job.
This transaction completes before any local actor or provider call starts.
Creation without a prompt also has a launch request.

Dispatch retries local startup until an actor acknowledges the request. The
acknowledgment and actor claim commit together under the original machine and
parent locks. Horde success or registry absence cannot acknowledge a request.
Acknowledged requests are never replayed by dispatch. Their unfinished machines
retain the existing actor-history fence against another provider create.

The request retains its tenant, parent, machine, runtime, opening receipt and
absolute deadline. Database triggers prevent identity and deadline changes.
Cancellation, changed ownership or admission refusal prevents a new claim.
Admission checks the deadline after its database waits; the watchdog receives
the same deadline. A late start failure cannot fail an acknowledged actor.
A bounded sweep restores missing dispatch jobs and retains incomplete jobs,
including suspended jobs, without duplicating them.

Normal reattach to a ready machine preserves the original launch ancestry.
Another owned conversation may attach to that shared machine without claiming
or changing the creator's launch. Neither path authorizes unfinished provisioning.

The local regressions cover creator death, duplicate actors, admission refusal,
cancellation, late failure, ready reattach and dispatch restoration. Independent
PostgreSQL connections test competing claims, claim-versus-failure outcomes and
a receipt lock held past the deadline. Provider calls in actor tests are stubs.
See `decisions/evidence/actor-launch.json` for validation and source hashes.

This is fresh-creation integration, not complete lifecycle recovery. Fresh
replacement now uses the same launch journal as described below. Ready-machine
startup uses a separate reconnect request as described below. Provider journal identity,
abandoned actors, interrupted prompt wakes and legacy rollout remain open.
Execution controls and provider recovery remain disabled pending live acceptance.


## Database-first fresh replacement (integration in progress)

Fresh wake previously reserved a new machine, asked Horde to start its actor,
then committed the replacement binding. Caller death could strand an unbound
reservation. The actor's short binding wait did not close that gap.

Fresh wake now commits source retirement, the replacement reservation, holder
transfers and its launch job in one transaction before local startup. Fleet and
account quota locks precede sorted machine locks and parent rows. The transaction
checks the original parent binding and the source snapshot again. A changed
provider identity, runtime, disk identity or source state rejects retirement.
Uncertain provider operations retain their fence and capacity.

The launch records its immutable purpose and source machine ID. Competing callers reuse that
saved replacement, including when the winner consumes the last account or fleet
slot. Horde's existing-actor response cannot change the database winner or retire
its reservation. Explicit startup failure records a failed launch; its immediate
API caller retains the startup error. An unused replacement releases its slot and
leaves the existing conversation retryable. An old-source actor claim cannot
strand that replacement, but all old claims and provider history remain intact.
Any actor or provider history on the new machine requires reconciliation instead.
Initial creation still reports a failed conversation when startup fails.
The outbox can retry a lost local start.

Shared-home retirement and idle-holder transfers commit with the new home and
launch. Invalid placement or a failed launch save rolls back all those changes.
Fresh wake carries the original prompt receipt ID through the invocation. A
cancelled receipt cannot silently become permission for a prompt-free launch.
The launch deadline cannot exceed the receipt's original delivery deadline.

Separate PostgreSQL connections test competing replacements at both quota caps,
a source identity change while wake waits, and a receipt lock held past expiry.
Real actor callbacks verify committed binding and acknowledgment before the
stubbed provider create. See `decisions/evidence/fresh-wake-launch.json`.

This proves local fresh-replacement handoff, not complete recovery. The next
section covers ready-machine startup. Suspended wake, abandoned actors, provider
identity links, conditional deletion and legacy rollout remain integration work.
The lifecycle stack stays draft; live acceptance still gates deployment and
activation of execution controls or provider recovery.


## Durable ready-machine reconnect (integration in progress)

Ready-machine wake and attachment now commit a reconnect request and dispatch job
before calling Horde. The request records the tenant, parent, runtime, machine,
provider identity, lifecycle generation, opening receipt and absolute deadline.
Acceptance checks the observed binding under the machine and parent locks. It
reserves no compute and permits no provider creation or resume.

Only one requested launch may exist per parent. Concurrent callers share that
request; different parents on a shared machine retain separate requests. A
partial unique index preserves one original creation or replacement per machine.
Reconnect history does not overwrite that original ancestry. The database
rejects changes to the saved reconnect identity. Migration rollback refuses to
erase reconnect history once requests exist.

The actor acknowledges its exact request atomically with its claim. Admission
rechecks the ready state, provider identity, operation fence, cancellation and
deadline. A stale stored child specification cannot bypass a newer request.
Startup refusal leaves the existing machine and conversation retryable. An
acknowledged request is never redelivered by the outbox.

Caller death after request commit leaves the dispatch job able to retry local
startup. A settled reconnect also proves that the original prompt wake handed
off after its provider phase returned. That evidence permits a later receipt to
request its own wake without replaying the old invocation. The old `started`
record remains intact; unrelated or unsettled wakes still fence new invocations.

Local tests kill the caller before Horde startup, recover through the committed
job, and submit a later prompt after normal actor retirement. Real actor callbacks
verify acknowledgment before provider access and reject creation on reattach.
Separate PostgreSQL connections exercise duplicate requests, duplicate claims,
claim/refusal races and admission locks held across identity changes or expiry.
See `decisions/evidence/ready-wake-launch.json` for the validation checkpoint.

This covers the local handoff after a ready machine has been selected. The
suspended-provider resume still precedes that handoff. Crashes before handoff,
abandoned acknowledged actors, bounded reattach completion, provider operation
links and legacy rollout need further integration. No provider operation is
replayed based on a missing process. The stack remains draft and undeployed;
live acceptance still gates execution controls and provider recovery.
