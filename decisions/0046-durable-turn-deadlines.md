---
type: ADR
title: "Durable turn deadlines and remote execution identity"
description: "Persist turn deadlines and provider-operation intent before I/O; the journal and typed policy are implemented, while transport and lifecycle enforcement remain unbuilt."
tags: [conversations, sandbox, reliability, limits]
status: draft
adr: "0046"
adr_status: "Proposed"
date: 2026-09-07
generated: { by: process:codex, at: 2026-09-07T23:43:51Z }
verified: { by: process:codex, at: 2026-09-08T00:21:51Z }
stale_after: 2026-09-15
---

# 0046 — Durable turn deadlines and remote execution identity

**Status:** Proposed; not shipped. The journal foundation is in draft
[Fountain #1744](https://github.com/BinaryBourbon/fountain/pull/1744), with passing
CI at `f7404395b49019e4d122b91ba7991330b49addd3`.

The typed-policy layer is in draft
[Fountain #1745](https://github.com/BinaryBourbon/fountain/pull/1745), with passing
CI at `cadeab6f88c13285ba2cc08f9fa2ae572b00e8b1`: validated host/account ceilings,
conversation allowance narrowing, immutable journal snapshots, HTTP admission
checks, API stop reasons, and SDK/CLI request fields are implemented. All nonempty
effective limits are currently refused because the runtime transport and deadline
worker are not integrated. There is no user-configurable bypass of that gate.
Validation passes 4,663 tests and 6 doctests in full precommit, all four SDK suites
and contract checks, CLI tests/vet, and 20 separate-connection database races.
The typed-layer evidence and prior failures are recorded in
`decisions/evidence/typed-execution-limits.json`.
The next local branch resolves ACP 0.4.0, Runtimes 0.4.1, Runner 0.2.2, and
Sandbox 0.3.0 from Hex; full precommit also passes on this set. The compatibility
releases, source bindings, and fresh-process check are recorded in
`decisions/evidence/execution-limit-dependencies.json`. The independent deadline
worker is not implemented yet. No deployment or production timeout activation
has occurred.

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
| `uncertain` | Result or ownership cannot be established; retain the fence. |
| `stopped` | That attempt was confirmed, or no spawn was ever submitted. |
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
| Deadline supervisor | Expire due rows, claim one termination, recover abandoned submissions as uncertain, publish the persisted outcome. |

Bounded connections also need a shutdown policy after successful replies: the
current warm connection can continue background work outside a turn. Completion
must not silently discard that obligation. Register before title generation,
adapter preparation, or any model prompt; keep cancellation intent ahead of
blocking provider writes.

Journal retention after confirmed cleanup and account deletion also needs an
explicit policy. Uncertainty must never be erased by transcript deletion.

`managoat_sandbox 0.3.0` supplies confirmed remote termination. Provider identity
notifications await [Sprites #33](https://github.com/superfly/sprites-ex/pull/33),
tracked through release and exact pinning in
[Review Loop #109](https://github.com/managoat/review-loop/issues/109).
Do not activate deadline claims using an unpublished or floating SDK dependency.

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

## Alternatives considered

- Actor mailbox timers cannot enforce a deadline during a blocked callback.
- Silence thresholds interrupt legitimate long checks without bounding a turn.
- Local disconnects and signals alone do not confirm that remote work stopped.
- Reconstructing success from writable markers cannot recover trusted exit evidence.
- Replaying uncertain operations can create duplicate workers or affect a successor.
