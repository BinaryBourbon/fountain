---
type: ADR
title: "A persistent sandbox per agent, offered beside the sandbox-per-conversation model"
description: "Sketch only — nothing here is built. Adds a second sandbox mode, chosen per launch and defaulted per agent, where one long-lived sandbox serves many conversations of an agent (the 'grokbot' shape); keeps the per-conversation mode as the default; names the seven places the code hard-codes 1:1 today. Companion design note: #805."
tags: [sandbox, lifecycle, conversations, product]
status: draft
adr: "0023"
adr_status: "Proposed"
date: 2026-08-17
generated: { by: human:jhgaylor, at: 2026-08-17T17:30:00-04:00 }
stale_after: 2026-10-01
---

# 0023 — A persistent sandbox per agent, beside the sandbox-per-conversation model

**Status:** Proposed — a design sketch. **Nothing described here is built.**
The 1:1 model of today is the only one that exists; every mechanism below is
a proposal, and the "what breaks today" section is a survey of the current
code, not a list of fixed defects.
**Date:** 2026-08-17 (amended 2026-08-18: mode is chosen per launch and
defaulted per agent, not fixed per agent; the machine carries a lease/refcount;
`sandbox_id` attach — see #805 for the holistic picture this converges on)

**Renumbered 2026-08-21:** this ADR was drafted as 0021 on 2026-08-18 and lost
the number to [0021](0021-oauth-for-first-party-apps.md) (OAuth for first-party
apps), which was opened later the same day and merged first. Line references in
the survey below were re-checked against `main` on the same date. Anything
citing "ADR 0021" for a persistent sandbox — #793, #805 — means this file.

**Companion:** #805 is the "if we had designed it this way from the start"
sketch — the sandbox as a first-class machine, a conversation as a binding of
an agent to one. This ADR is the incremental proposal; #805 is what it should
be measured against.

## Context

### The decision we made, and why

Fountain provisions one sandbox per conversation
(`conversations.ex:6` — "v1 keeps these 1:1"; the public schema doc says "one
chat with one agent inside one sandbox"). The reasons were good and still
hold for the cases they were chosen for:

- **Isolation as the only defence.** Every runtime runs with permission
  prompts bypassed (0014); the sandbox is the whole security boundary. A fresh
  sandbox per conversation means a bad turn poisons one transcript, not an
  agent's entire history.
- **Fan-out is the headline use case.** The bundled `fountain` skill and
  `parent_conversation_id` exist so one agent can spawn N children that each
  get "its own fresh Sprite" and run concurrently on separate disks.
- **The lifecycle is simple.** Conversation and sandbox share a lifetime, so
  idle/ceiling/terminate/wake all reason about one row, and
  `max_concurrent_sandboxes` is a concurrent-conversation cap for free.

### What people want instead

The "grokbot" shape is one long-lived machine per agent: every conversation —
every Buzz channel, every DM, every UI chat — lands on the same disk. The
appeal is not cost; it is that **the disk is the agent's memory**. Notes,
cloned repos, installed tools, `~/.claude` project state and the agent's own
scratch files accrue across conversations. Our per-conversation model
guarantees amnesia across conversations by construction, and 0017 already
conceded the same point *within* a conversation ("every idle reclaim
guaranteed the agent's amnesia to save money we were not spending").

The two models serve different jobs and we should offer both, not replace one
with the other:

| | Per-conversation (today) | Persistent per agent (this ADR) |
|---|---|---|
| Sandbox lifetime | = the conversation's | = the agent's (until reset/deleted) |
| Cross-conversation memory | none | shared disk, shared runtime session store |
| Concurrency | N conversations = N sandboxes, fully parallel | one machine; turns serialized (see below) |
| Best for | fan-out, one-shot tasks, untrusted inputs | assistants, channel bots, "my agent's computer" |
| Blast radius of a bad turn | one conversation | the agent's whole state |

### The 1:1 assumption is structural, not incidental

The schema is already N:1 (`Sandbox has_many :conversations`,
`conversations/sandbox.ex:35`) and the reaper is already written for N
(`server_alive?` and `last_activity_at` fold over all of a sandbox's
conversations; `_unsafe_reap_sandbox` terminates all of them). But no write
path ever produces a second conversation on a sandbox row, and these paths
would misbehave if one did:

1. **Reattach binds to the wrong process.** `attempt_session_attach`
   (`conversation_server.ex:1000`) takes the *head* of the sandbox's session
   list. Two conversations' detachable turns on one sandbox → a reattaching
   server streams B's agent into A's transcript. Sessions carry only a
   provider id and a command line, no conversation tag.
2. **Per-conversation identity lives at one shared path.** `/home/sprite/.env`
   (`provisioning.ex:32`) mixes environment/vault values with
   `FOUNTAIN_TOKEN` (the per-conversation callback key) and
   `FOUNTAIN_CONVERSATION_ID`, and is rewritten on every reattach
   (`conversation_server.ex:689,880`). Two conversations would stomp
   each other's identity.
3. **cwd is per runtime, not per conversation** (`runtimes/acp.ex:113-145`):
   claude/codex share `/home/sprite`, opencode a single sqlite db and an HTTP
   port, gemini `--resume`s "the most recent conversation in the workspace"
   (`gemini.ex:62`; called out as unsafe at `acp.ex:33-36`). ACP session ids
   themselves are explicit and safe; the disk around them is not.
4. **Terminate/park/destroy flip the shared row for one conversation.**
   `:terminate_conv` (`conversation_server.ex:1390`) destroys the sprite
   unconditionally; `park_sandbox` (`:1886`) suspends the row when *this*
   server's clock says idle — on Daytona/E2B that is a real pause of the other
   conversation's running turn.
5. **Idle/ceiling verdicts are per-server state acted on per-row**
   (`conversation_server.ex:1571-1588`, `sandbox_reaper.ex:211-250`).
6. **Quota counts sandboxes as a proxy for concurrent runs** (`quotas.ex:32`).
   Share sandboxes and the cap stops bounding compute.
7. **Wake's fallback repoints one conversation to a fresh row**
   (`conversations.ex:1536-1541`) and retires the old one, orphaning
   co-tenants; the schema comment at `conversation.ex:52` already describes
   only this fallback.

Also worth naming: `sandboxes` has no `agent_id` — a sandbox is not findable
by the identity a persistent mode needs; sprite names are random per call
(`fountain-<tenant>-<hex>`) so nothing reuses by name; and checkpointing is
disabled *because* names are fresh each time (`conversation_server.ex:748`).

## Decision (proposed)

Add a **sandbox mode** with two values. The mode is a property of the
**launch**, defaulted from the agent — the same shape `environment_id` has had
since #783: the agent's setting is the default, a conversation may name another
at launch. The agent is the brain (model, runtime, skills, MCP); it holds an
opinion about *where* it runs only as a default.

- `ephemeral` — a sandbox per conversation. Unchanged, and the default.
- `persistent` — one sandbox per **agent identity**, where the identity is
  `(agent_id, environment_id, vault_id)`: the same key `find_channel_conversation`
  already resumes by, for the same reasons (#727: two vaults on one agent are
  two identities; #783: an environment override is a different baseline). A
  persistent sandbox is a "home" — the agent's computer.

So agent `foo` may run ephemeral in one conversation and on its home in
another; a persistent-by-default agent may fan out ephemeral children; a
second conversation may be opened *onto* an existing home by `sandbox_id`.
Which of these a launch does is decided at the door, not baked into the agent.

Concretely, in the order the pieces depend on each other:

**1. Make the sandbox row findable by identity.** `sandboxes` gains
`agent_id`, `vault_id`, `mode`, and a partial unique index on
`(user_id, agent_id, environment_id, vault_id) WHERE mode = 'persistent' AND
status NOT IN ('terminated','failed')`. The row is designed as if it were a
first-class machine — its identity does not depend on any conversation.
`start_conversation` takes `sandbox_mode` (launch attr, default
`agent.sandbox_mode`) and optionally `sandbox_id`:

- `sandbox_id` given → attach to that home (tenant-scoped; must be
  `persistent`, must belong to the same agent identity — a home is never
  shared across agents).
- mode `persistent` → `find_or_create_home/4` under the existing per-user
  advisory lock.
- mode `ephemeral` → `create_sandbox` as today.

Wake stops repointing: a persistent conversation resolves its sandbox by
identity, so if the home has to be re-provisioned (sprite gone), every
conversation on it follows automatically.

**2. Move per-conversation identity off the shared disk.** `FOUNTAIN_TOKEN`,
`FOUNTAIN_CONVERSATION_ID` and `TRACEPARENT` become **per-turn process env**
on the exec that spawns the ACP peer, not lines in `/home/sprite/.env`. The
`.env` file keeps only environment + vault values (identical for every
conversation on the home, by construction of the identity key). This change is
correct for the ephemeral mode too and can land first, on its own.

**3. Tag detachable sessions with the conversation.** Spawn the turn's session
with a recognisable marker (a `FOUNTAIN_CONVERSATION_ID=<id>` prefix on the
command line, or provider metadata where the adapter supports it), and make
reattach filter `list_sessions` by it instead of taking the head. Also correct
for ephemeral mode (it closes a latent bug that only 1:1 hides).

**4. Serialize turns per home, and make the lease the machine's refcount.** One
machine, one agent process at a time — this is the grokbot semantics and it
sidesteps every shared-cwd, shared-sqlite, shared-port problem in one move.
Mechanism: a per-sandbox lease (`Horde.Registry` keyed by
`{:sandbox, sandbox_id}`, or a small `SandboxServer` that hands out one turn
slot). The same registry answers "does any conversation hold this machine
right now?", which is what every lifecycle decision in (5) needs — park, ceiling
and destroy become **machine operations guarded by the lease**, not per-row
flips made on one conversation's say-so. A ConversationServer that wants to `kick_turn`
on a persistent home acquires the lease or queues; queued turns surface as a
`queued` stage in the log so the UI/Buzz can show "waiting for the agent".
Bound the queue (per-home depth, e.g. 8) and reject beyond it. Concurrent turns
on one home are explicitly out of scope for v1 — if we ever want them, they
need per-conversation cwd subdirs, and that gives up the shared-workspace
property that is the point.

**5. Split the lifecycle by mode.**

| Event | ephemeral (unchanged) | persistent |
|---|---|---|
| conversation terminated | destroy sprite, row `terminated` | revoke that conversation's callback key; sandbox untouched |
| idle timeout | park row `suspended` | park only when **no** conversation on the home has a live server (registry check), else no-op |
| max lifetime (continuous run) | destroy | **force-suspend**: kill the running exec sessions, park the row. Disk is the product; destroying it on a busy-ceiling would defeat the mode. State honestly in the stage message that the in-flight turn was cut. |
| provision failure | row `failed`, conv `failed` | row `failed`, conv `failed`; next conversation on the identity re-creates the home |
| agent deleted / vault or env changed | n/a | destroy the home (identity no longer exists); a "reset home" action does the same on demand |
| reaper abandoned pass | as today | as today — already N-aware |

**6. Quota semantics stay "sandboxes", plus a turn bound.** A home counts as one
toward `max_concurrent_sandboxes` while `ready`; serialization (4) means one
home = at most one running turn, so the cap still bounds compute. Add
`max_conversations_per_home` only if the queue depth from (4) proves
insufficient.

**7. Runtimes.** claude and codex work as-is on a shared cwd once turns are
serialized (sessions resumed by explicit id). opencode works once serialized
(single db, single port). gemini stays excluded from persistent mode until it
is on the ACP path (#659) — its legacy `--resume` is exactly the guess that
breaks. Enforce with `Runtimes.ACP.supported_runtimes/0` at agent save time.

**8. Surface — every launch door, the same shape.** `PATCH /api/agents/:id`
gets `sandbox_mode` (the default); the agent form gets a radio with the table
above as copy. Every door that starts a conversation accepts the override:
`POST /api/conversations` (`sandbox_mode`, `sandbox_id`), `fountain run` /
`fountain conversations create` (`--sandbox-mode`, `--sandbox`), ACP
`session/new` `_meta`, Buzz provision, and the `fountain` skill's fan-out. No
allowlist for the override — unlike `environment_id`, the mode is not a
security boundary; the tenant scope on `sandbox_id` is. **Channel resume takes
the agent default**, not a per-message override: a channel identity should be
stable, and `find_channel_conversation` already lands each channel on one
conversation, so persistent mode makes those conversations share a disk —
which is what a channel bot wants. The conversation list shows a "home" badge
and the sandbox row gets its own detail (status, last resumed, disk age,
conversations on it, reset button).

Not a fifth primitive *in the UI* — yet. The sandbox row already exists as the
record; giving it `agent_id`, a mode and a lease is enough, and it should be
designed as if it were one (#805): a machine whose identity does not depend on
any conversation. Promote it to a user-facing "Machine" only if the UI needs
to show something a conversation-centric view cannot.

## Consequences

- **Memory across conversations, at the cost of blast radius.** In persistent
  mode a prompt injection in one channel can read and alter what every other
  conversation on that agent left on disk. This is inherent to the model and
  is the trade the user makes by choosing it; the mode-selection copy must say
  so, and it is one more reason the identity key includes the vault (a
  compromised home never holds two identities' credentials).
- **Fan-out and persistence compose, per launch.** Children spawned via the
  `fountain` skill go through `start_conversation`, so a persistent parent can
  fan out ephemeral children (fresh disks, parallel) or, by passing its own
  `sandbox_id`, children onto its home (shared disk, serialized) — the choice
  is the launch's, not the agent's. Two agents can never share a home
  (identity includes `agent_id`), so per-agent skill mounts at the
  runtime-global skills path do not collide.
- **Steps 2 and 3 improve the ephemeral mode on their own** and should ship
  first as bug fixes; nothing else in this ADR is needed to justify them.
- **Checkpointing becomes meaningful.** With a stable, named home the
  "fresh name each time" reason to keep checkpoints disabled goes away.
- **The `suspended`-never-aged-out cost from 0017 grows** in the way that
  ADR anticipated: homes accumulate one sprite per agent identity per tenant,
  forever. Still treated as zero until it isn't; the retention knob 0017 names
  is the answer.
- **Metering.** A home that stays `ready` under back-to-back turns from many
  conversations bills as one sandbox. That is the intended cost shape but it
  is a different plan shape from "runs"; billing may want to price the mode
  (always-on agent) rather than the sandbox-minutes.

## Alternatives considered

- **Replace the per-conversation model outright.** No — fan-out and
  untrusted-input jobs want fresh disks; the two are different products.
- **Per-conversation cwd subdirectories inside one sandbox, concurrent turns.**
  Keeps parallelism but gives up the shared workspace that is the whole reason
  people want this, and reintroduces the shared-`~/.claude`/sqlite/port
  problems. Possible later as a third mode; not the first one.
- **A shared sandbox per *user* (one machine for all agents).** Skill mounts,
  runtime configs and vault credentials from different agents would collide on
  one disk; the identity key would have to be the user and every credential
  the user owns would sit on one machine. Rejected.
- **A new "Machine" primitive with its own CRUD.** Cleaner ownership story,
  but the sandbox row already is the machine; add a mode and an agent pointer
  first and promote only if the UI demands it.
- **Sandbox provider snapshots/forks (clone the home per conversation).**
  Gives memory *and* isolation, but 0018's provider matrix does not offer it
  uniformly (Sprites checkpoints exist; E2B/Daytona differ) and it is a
  different, larger project.

## Open questions

- Should a persistent home wake on **any** inbound (Buzz mention at 3am) or
  only on the owner's turns? Today wake is per prompt; a home makes "the
  agent is asleep" a visible product state.
- Ceiling behaviour: force-suspend as proposed, or exempt homes from the
  continuous-run ceiling entirely (a chatty channel bot may never be idle for
  four hours)?
- Whether the identity key should ignore `environment_id` (one home per agent,
  environment override refused in persistent mode) — simpler mental model,
  fewer homes, at the cost of #783's flexibility. Put differently (#805):
  should a home be re-materializable in place with a different environment or
  vault, or is that always a different machine?
- Pricing: mode-based (always-on agent) vs sandbox-minutes as today (#798).
- Concurrency: is serialized-turns-per-home acceptable for v1, or does the
  target user expect parallel turns on one machine?
- Should `sandbox_id` attach be allowed onto a home that is currently
  `suspended` (wake it) — probably yes — and onto one whose agent has since
  changed runtime (probably refuse; the disk was shaped by the old one)?

## Gates (if accepted)

1. Per-turn identity env + session tagging (steps 2–3) — ships alone,
   ephemeral-only benefit, no schema change.
2. `sandboxes.agent_id/vault_id/mode` + partial unique index + `find_or_create_home`.
3. Per-home turn lease + queued stage.
4. Lifecycle split (terminate / park / ceiling / reset / agent-delete).
5. Agent default + per-launch `sandbox_mode` / `sandbox_id` on every door
   (API, CLI, ACP `_meta`, Buzz provision, `fountain` skill), UI copy, docs;
   gemini exclusion.
6. Live smoke: two Buzz channels on one persistent agent, prove shared disk
   and correct per-channel transcripts under interleaved turns.
