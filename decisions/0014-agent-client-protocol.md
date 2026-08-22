---
type: ADR
title: "Speaking the Agent Client Protocol to runtimes"
description: "ACP is the only runtime I/O path for claude, codex and opencode, adopted behind gates; Fountain.Runtimes stays the provisioning layer. Gates 1 and 2 built, gate 4 in progress, gate 3 not built."
tags: [acp, runtimes]
status: stable
adr: "0014"
adr_status: "Partially accepted"
date: 2026-08-09
generated: { by: human:jhgaylor, at: 2026-08-14T00:25:23-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-14T00:25:23-04:00 }
stale_after: 2026-11-14
---

# 0014 — Speaking the Agent Client Protocol to runtimes

**Status:** Partially accepted — **gates 1 and 2 are built; gate 4 is in
progress; gate 3 is not built.** ACP is the **only** way Fountain speaks to
claude, codex and opencode: their legacy spawn path (`build_command/5`, the
permission-bypass flags, the claude-only stream tracer) was deleted on
2026-08-14, and the per-agent `metadata["acp"]` flag — gate 2's opt-in, then
briefly a default-on opt-out — was retired with it, since there is nothing
left to opt out into. Their MCP config travels only in `session/new` (#636)
and every ACP turn gets protocol-keyed tool spans (#637). Gemini takes the
legacy path — an upstream defect, not a choice; see gate 4. Nothing in *Gate 3
— permissions* exists, and it should not be read as describing behaviour the
system has. Each gate below carries its own status; the PR that builds one
removes its caveat.

## Context

Fountain supports four coding-agent CLIs, and pays for each one twice.

**Once at spawn.** `Fountain.Runtimes` (`apps/fountain/lib/fountain/runtimes.ex`)
is a six-callback behaviour that exists entirely because the four CLIs
disagree about argv, credentials, session resume, config files and where
skills live on disk.

**Again at render.** `FountainWeb.ConversationsLive.Show` carries 24 clauses of
`event_blocks/2` (`show.ex:1340-1530`) — four hand-written parsers for four
proprietary line-delimited JSON dialects, living in a LiveView. Adding a fifth
runtime means writing a fifth parser, in the render path, against an
undocumented stream format that its vendor may change in a point release.

Those parsers all reduce to the same small vocabulary, and it is very close to
one that already has a specification. The Agent Client Protocol (ACP,
<https://agentclientprotocol.com>) is JSON-RPC 2.0 between a *client* (an
editor, or in our case Fountain) and an *agent* (the CLI). Its
`session/update` notification carries exactly the block kinds we reconstruct
by hand:

| `show.ex` block | ACP `session/update` variant |
|---|---|
| `%{kind: :text}` | `agent_message_chunk` |
| `%{kind: :thinking}` | `agent_thought_chunk` |
| `%{kind: :tool_use}` | `tool_call` — `id`, `title`, `kind`, `rawInput`, `locations` |
| `%{kind: :tool_result}` | `tool_call_update` — same `id`, plus `status` |
| `%{kind: :init}` | the `session/new` response |
| `%{kind: :result}` | the `session/prompt` response's stop reason |
| — | `plan`, `available_commands_update` (no Fountain equivalent) |

`pair_tool_results/1` (`show.ex:1293`) exists only because three of the four
dialects emit a tool call and its result as unrelated top-level events that we
have to rejoin by id. ACP threads them on one `id` by construction.

Two further things the current design cannot express, both of which cost us
something real:

**We run every agent with its safety rail removed, and it is not a choice.**
`claude.ex:39` passes `--dangerously-skip-permissions`; `gemini.ex:50` passes
`--approval-mode yolo`; `codex.ex:51` passes
`--dangerously-bypass-approvals-and-sandbox`; `open_code.ex:46` passes
`--dangerously-skip-permissions`. A headless CLI has no channel back to a
human, so bypass is the only way it runs unattended. The sprite sandbox is
therefore not defence *in depth* — it is the only defence there is. ACP's
`session/request_permission` is an agent→client request: the agent blocks and
the client answers. That is a channel we do not have and cannot build without
forking four CLIs.

> **Correction, 2026-08-21.** The paragraph above describes 2026-08-09 and is
> kept for the reasoning that motivated the ADR, but three of its four flags no
> longer exist: claude, codex and opencode lost theirs when the legacy spawn
> path was deleted (#671-#675). Only `gemini.ex:50` still passes
> `--approval-mode yolo`, and only because gemini is held back from ACP by an
> upstream defect (#659).
>
> The rail is still off, but it is off in **one function Fountain owns**:
> `permission_outcome/1` (`runtimes/acp/peer.ex:747`) answers every request by
> picking `allow_always`, else `allow_once`, else the first option offered,
> plus one pre-approval at session setup (`enableAllProjectMcpServers`,
> `claude.ex:93`). That is a smaller and much more tractable problem than the
> one this ADR was written against: the channel exists, the request arrives
> with its tool name and option list intact, and what is missing is a policy
> to consult instead of a constant. See gate 3.

**Two runtimes resume by guessing.** `gemini.ex:14-17` documents that
`--resume` re-enters "the most recent conversation in the workspace" because
Gemini will not accept a session id; `codex.ex:24-26` documents the same for
`--last`. Correct only while one conversation ever runs in a workspace —
an invariant we hold by accident, not by construction, and one that no test
asserts. ACP's model is `session/new` once, then N× `session/prompt` over one
live connection, with `session/load` for genuine resume. The id is explicit.

## Decision

Adopt ACP as Fountain's **runtime I/O layer**, incrementally and behind gates,
while keeping `Fountain.Runtimes` as the **provisioning** layer. Do not
attempt a cutover.

The split is the load-bearing part of this decision. ACP has no opinion about
how the agent binary, its credentials, its skills or its MCP servers got into
the sandbox. So `default_env/2`, `write_config/2`, `prepare_sprite/3`,
`skills_root/0` and `skills_sh_agent/0` all survive unchanged; only
`build_command/5` and the four render-path parsers are in scope. Roughly half
of `Fountain.Runtimes` is untouched by this ADR, and that is the expected
end state, not a transitional one.

### The shape, drawn

This ADR is the lower half of the picture; [0015](0015-fountain-as-an-acp-agent.md)
is the upper half. Both are drawn here so that neither is read as a tree with
the other hanging off it — they are two protocol roles held by one process.

```
  ┌─ editor (Zed, VS Code, …) ─────────────┐   ┌─────────────┐
  │  spawns  ▸  fountain acp               │   │   web UI    │
  │              ▲   ACP over local stdio  │   │ (LiveView)  │
  └──────────────┼─────────────────────────┘   └──────┬──────┘
                 │  HTTP + SSE                        │  WebSocket
                 ▼                                    ▼
  ┌─────────────────────────────────────────────────────────┐
  │                        fountain                         │
  │    ACP *agent* upward (0015) · ACP *client* downward    │
  │    (0014) — the four runtime dialects stop at this line │
  └────────────────────────────┬────────────────────────────┘
                               │  ACP over the sprite's stdio
                               ▼
  ┌─────────────────────────────────────────────────────────┐
  │      sprite  —  where the workspace and the files are   │
  │        claude  ·  codex  ·  gemini  ·  opencode         │
  └─────────────────────────────────────────────────────────┘
```

Two things the boxes are there to make hard to misread.

**The vertical edges are asymmetric, and the traffic runs both ways on each.**
`session/prompt` travels down and its stop reason comes back up;
`session/update` only ever travels up; `session/request_permission` originates
at the *bottom* and is answered from the top — the one place Fountain must
carry a request upward and an answer back down.

> **Amendment, 2026-08-21.** This sentence used to end "which is why gate 3
> below is the gate that justifies the project". That claim is withdrawn. #644
> departed from it on 2026-08-13 and gate 4 records the reasoning: if the
> justification is deleting per-runtime code, permissions belong *after* the
> conversions rather than gating them. The conversions have since landed and
> paid for themselves without gate 3. The asymmetry described here is still
> the interesting part of the protocol; it is not what the project rests on.

**Placement is not on this diagram, and that is deliberate.** Which sandbox
platform runs the sprite, and in whose cloud, is a separate axis that ACP says
nothing about — it lives in `prepare_sprite/3`, `default_env/2` and
`write_config/2`, the half of `Fountain.Runtimes` this ADR does not touch.
ACP unifies the leaves; it does not make the substrate pluggable, and adopting
it buys nothing toward that. A diagram that hangs runtimes off cloud providers
is describing a decision nobody has written.

### Session lifetime: the connection is scoped to the turn

The sandbox is the cost unit and it has to stay disposable. `Lifecycle`
(`apps/fountain/lib/fountain/conversations/lifecycle.ex`) reclaims an idle
sprite after 60 minutes and any sprite after 24 hours, and the reason that is
safe is that the conversation row stays `idle`, `runtime_session_id` is
persisted *before* the turn spawns (`conversation_server.ex:1595`), and the
next prompt provisions a fresh sprite and resumes.

> **Correction, 2026-08-10.** That last clause is not true, and gate 2's live
> run proved it: the runtime's session lives in the sandbox's filesystem, so a
> reclaimed conversation resumes onto a sprite that has never heard of it.
> Both `session/resume` and the legacy `--resume` fail with *not found*. See
> *The reclaim finding* under gate 2. The reclaim/bill asymmetry this paragraph
> was built on is real for **cost** and false for **continuity**, and the gap
> predates ACP.

Nothing in this ADR is allowed to make the cost side worse, which is what the
rule below protects.

An earlier draft of this document said "ACP wants one connection alive for the
session" and filed the collision with `SandboxReaper` under mandatory scope.
That conflated two things the specification keeps apart. A session is named by
its `sessionId` and is independent of the connection that created it —
`session/load` exists so a *different* client instance can pick one up, after
which the client "can then continue sending prompts as if the session was
never interrupted." And a turn has a defined end: "if there are no pending
tool calls, the turn ends and the Agent **MUST** respond to the original
`session/prompt` request with a `StopReason`."

Nothing in ACP requires a connection to outlive a turn. So:

> **One ACP connection per turn.** Spawn the agent, `initialize`,
> `session/new` on turn 1 or `session/load` / `session/resume` on turn N,
> exactly one `session/prompt`, take the `stopReason`, close. Nothing is
> attached between turns. `SandboxReaper`, the rehydrator and `Lifecycle` are
> untouched by this ADR.

That is the shape we already run, with the protocol swapped in underneath it:

| today | under ACP |
|---|---|
| `Sprites.spawn` per turn (`conversation_server.ex:1683`) | the same spawn; the process speaks ACP |
| prompt written to stdin, then `close_stdin` | prompt in `session/prompt`; **stdin stays open** for the connection |
| `--resume <runtime_session_id>`, `--last` | `session/load` or `session/resume`, same persisted id |
| process exit ends the turn | the `session/prompt` response ends it; exit is the backstop |
| idle sprite reclaimed at 60m, any sprite at 24h | unchanged |

> **Addendum, 2026-08-16 — the connection is scoped to the turn, but the
> server is not.** Every deploy restarts every `ConversationServer`, and the
> adapter in the sprite is a detachable session that keeps running with
> `session/prompt` outstanding. The reattach path (`attempt_session_attach`)
> re-hooked the command and logged its stdout raw — no peer — so nobody
> answered `session/request_permission` and nobody saw the prompt response;
> with 24 deploys in a day, every ACP turn in flight across one hung until the
> user prompted again or the sandbox hit its 24h ceiling (eight found stuck in
> production, one 15 hours in). Two things now hold: the peer reports the
> prompt's JSON-RPC id and the server persists it on the turn
> (`turns.acp_prompt_id`), and a reattach starts a peer with `attach:
> prompt_id` that resumes exactly that request — no handshake, replayed
> handshake ignored, live requests answered. A turn without the id (the peer
> died mid-handshake) is orphaned and its adapter stopped rather than left to
> hang. Sprites replays only the last 16 KiB of the session, mid-line, so
> replayed lines are de-duplicated by content, not by the byte count the
> legacy path still uses.

**The rule that keeps this from eroding one optimisation at a time: no ACP
state may become a reason to keep a sandbox alive.** A connection may be
scoped to the turn (v1) or, if per-turn `initialize` proves too slow, to the
sandbox's own idle window — both are bounded by `Lifecycle`. A connection
scoped to the *session* is out of bounds, because it makes protocol state
outrank the cost control, and that is the form in which this decision would
come back to bite us.

### Gate 1 — survey, no code — **done, 2026-08-09**

Confirm per runtime how ACP support is actually provided and what the version
floor is, because a runtime needing a vendored Node adapter in the sprite
image is a materially different proposition from one that speaks ACP with a
flag. **Result below; the recommendation changed as a result of running it.**

The survey must also record, per runtime, the two capability flags the
turn-scoped connection depends on: `agentCapabilities.loadSession` and
`sessionCapabilities.resume`, both read from the `initialize` response.
Under one-connection-per-turn these are not a convenience for genuine resume —
they are the *only* thing carrying a conversation across turns.

**A runtime that advertises neither is not convertible.** Without one of them
we would be doing resume-by-guessing exactly as we do today, plus a JSON-RPC
peer: strictly worse than what we ship. That is a rejection, not a gap to work
around, and it applies whatever the adapter's other merits.

It also makes gate 2's candidate conditional. Gemini is the interesting spike
*because* its resume semantics are the weakest thing we ship — but that is
only true if its ACP path advertises a resumption capability. If it does not,
the spike fixes nothing and the candidate is whichever runtime does.

#### Result

Read from each implementation's `initialize` response in source, not from
documentation, on 2026-08-09. Versions are the npm `latest` on that date.

| Runtime | Mechanism | Launch | Verified at | `loadSession` | `sessionCapabilities.resume` |
|---|---|---|---|---|---|
| Claude | adapter, on the **Claude Agent SDK** | `claude-agent-acp` (`@agentclientprotocol/claude-agent-acp`) | 0.66.0 | ✅ `true` | ✅ `resume: {}` |
| Codex | adapter, on the **Codex App Server** | `codex-acp` (`@agentclientprotocol/codex-acp`) | 1.1.14 | ✅ `true` | ✅ `resume: {}` |
| Gemini | native | `gemini --acp` | 0.54.4 | ✅ `true` | ❌ **no `sessionCapabilities` block at all** |
| OpenCode | native | `opencode acp` | 1.18.15 | ✅ `true` | ✅ `resume: {}` |

**All four are convertible.** The rejection criterion above — advertises
neither — applies to none of them, so gate 1 rejects nothing.

**The spike runtime is Claude, not Gemini.** Gemini advertises `loadSession`
and no resume, and its `loadSession` streams the conversation back to the
client. Under one connection per turn that is the full history replayed on
every turn after the first, which is the most expensive shape available and
the one gate 2's replay-discard requirement exists to survive. Claude
advertises both, and the two paths are visibly different in its source:
`resumeSession` only reattaches (`getOrCreateSession`), while `loadSession`
additionally calls `replaySessionHistory`. So for Claude the ACP path is a
like-for-like swap for `--resume` at the same cost, with an explicit session
id instead of an implicit one. Gemini remains worth converting — its
resume-by-guessing is still the worst thing we ship — but it is the wrong
runtime to learn the protocol on.

Five things the survey turned up that the rest of this ADR has to absorb:

- **Both adapters changed hands during the drafting of this ADR.** The Zed
  packages named in earlier revisions are gone: `zed-industries/claude-code-acp`
  now redirects to `agentclientprotocol/claude-agent-acp`, and
  `zed-industries/codex-acp` is **archived** (last push 2026-07-22) behind a
  notice pointing at `agentclientprotocol/codex-acp`, rebuilt on the new Codex
  App Server. Both replacements are active. This is precisely the risk
  [0016](0016-governance-as-an-acp-proxy.md) names — "a vendor dropping an
  adapter turns a governed runtime into an ungoverned one" — and it fired
  inside a month. The mitigating detail is the direction: the adapters moved
  *to* the protocol org, not into abandonware.

- **The Claude adapter does not wrap the `claude` CLI.** It is a separate
  agent built on the Claude Agent SDK, so the sprite runs `claude-agent-acp`,
  not `claude`. That put a question mark over this ADR's claim that the
  provisioning half of `Fountain.Runtimes` survives unchanged, since
  `skills_root/0` (`/home/sprite/.claude/skills`) and `skills_sh_agent/0`
  (`claude-code`) describe the *CLI's* discovery paths.

  **Resolved 2026-08-10, in favour of the claim:** a skill written to
  `/home/sprite/.claude/skills/<name>/SKILL.md` was discovered and used by the
  adapter on a live sprite. The SDK reads the same tree, so both callbacks are
  correct as they stand and the provisioning layer really is untouched.

- **Nothing is version-pinned today, so there is no floor to hold.** Claude,
  Codex and Gemini come from the sprite base image, which we do not control;
  OpenCode is installed at provision time with `bun install -g opencode-ai`
  (`open_code.ex:85`), unpinned. We therefore cannot currently guarantee an
  ACP-capable version at spawn for any runtime. Pinning the adapter and the
  runtime is a **prerequisite of gate 2**, not a follow-up — an unpinned
  adapter is a supply-chain surface that also silently decides whether the
  feature works.

- **ACP v2 exists in the published spec and changes exactly this area.** It
  drops `session/load` altogether, keeps `session/resume`, and makes replay
  opt-in — "by default, resume restores the session context without replaying
  prior conversation history," with an explicit `replayFrom: {"type":
  "start"}` for clients that want it. That is the turn-scoped design as a
  first-class protocol shape. It is not announced as stable (the
  announcements page carries only v1 stabilisations, most recently
  2026-07-24) and all four implementations advertise v1-shaped capabilities
  today, so gate 2 targets v1 and must record which version it negotiated.
  Everything quoted in this ADR is v1.

- **`ANTHROPIC_BASE_URL` is honoured by the Claude adapter**, alongside
  `ANTHROPIC_API_KEY`. Our existing credential injection therefore works
  unchanged, and it answers half of 0016 §4's base-URL question — the one
  flagged there as "gate-1-shaped" — positively, for one runtime. The other
  three are unverified and stay that way until 0016 gate 3 needs them.

One process note, since it decides how much of this to trust: `opencode acp`
starts a local HTTP server inside the sprite and drives it through an SDK
client, rather than being a plain stdio peer. It satisfies the protocol, but
it is a heavier process model than the other three and should not be assumed
equivalent when its turn comes at gate 4.

### Gate 2 — one runtime, behind a per-agent flag — **done, 2026-08-10**

Build `Fountain.Runtimes.ACP` as a JSON-RPC peer over the stdio pipe we
already own (`Fountain.SpriteStdin.write/2` for the write half, the existing
stdout tail for the read half), for exactly one runtime, selected by gate 1.

The peer must translate `session/update` into **the same block maps
`show.ex` already renders**. The LiveView does not change in this gate. That
constraint is what makes the two paths A/B-able on one screen, and it is the
only way we find out whether the ACP stream is actually richer or merely
different.

Three requirements come from the turn-scoped connection above, and each is a
concrete bug if it is missed:

- **stdin stays open, and the turn gains a second terminator.** Today the
  prompt is written and `close_stdin` follows immediately. An ACP peer needs
  the write half open for the whole connection — it is the return path for
  `session/request_permission` answers and for `session/cancel` — so
  `close_stdin` moves to turn end. The turn then ends on *either* the
  `session/prompt` response or process exit, whichever arrives first, and
  never waits for both. #603 and #413 are both this class of bug: a turn whose
  terminator never came, leaving `current_command` set forever.

- **Discard the `session/load` replay.** The agent "**MUST** replay the entire
  conversation to the Client in the form of `session/update` notifications"
  before responding to `session/load`. Fountain already holds that history as
  `LogEvent` rows, so a peer that persists what arrives before the `session/load`
  response duplicates the whole transcript into the database and onto the SSE
  stream, on every turn after the first. The peer runs in replay-discard mode
  until `session/load` returns. Where `sessionCapabilities.resume` is
  advertised, prefer `session/resume`: it is specified *not* to replay, which
  deletes the failure mode instead of handling it.

  > **Correction, 2026-08-11.** "Until `session/load` returns" is not a
  > sufficient rule, because an agent may not honour the MUST. Gemini calls its
  > `streamHistory` as a floating promise and answers `session/load` *first*,
  > so the replay arrives after the response and lands outside the window —
  > measured live as a duplicated assistant message (#657). The peer now closes
  > the window on a **bounded quiet period** rather than on the response: keep
  > discarding until no `session/update` has arrived for 250 ms, then prompt,
  > capped at 10 s so an agent that never goes quiet cannot hold a turn open
  > (#413's shape). Timing is the only available discriminator — replay and
  > answer are the same notification on the same session, and what separates
  > them is that the answer cannot begin before we send `session/prompt`. The
  > cap comes off if the one-word upstream fix (`await`) lands.

- **Measure the per-turn `initialize`.** Process start, `initialize`, and the
  resumption round trip are now paid once per turn rather than once per
  session. That is the honest price of a disposable sandbox, and gate 2 must
  report it against the current spawn. If it is intolerable, the escape hatch
  is the sandbox-scoped connection named above — never a session-scoped one.

Ship it off by default, enabled per agent, with the legacy path intact.

#### Result — built, 2026-08-10

Built for Claude, off by default, behind `agent.metadata["acp"] == true`.
`Fountain.Runtimes.ACP` decides and provisions; `…ACP.Protocol` frames;
`…ACP.Peer` holds one connection for one turn; `…ACP.Blocks` translates. The
peer is a separate GenServer, monitored in both directions rather than linked,
so a protocol bug fails a turn instead of taking down a `ConversationServer`
holding a sprite handle and a tenant's secrets.

`log_events` gained an `acp` stream carrying `session/update` notifications,
one per line — the protocol as it arrived, exactly as `stdout` rows carry raw
output. `show.ex` gained a single delegating clause keyed on that stream. That
is not quite "the LiveView does not change", and the difference is worth
naming: a fifth *parser* in the render path was the thing this ADR set out to
avoid, and there is none. The clause dispatches to a module with its own
tests. Keying on the stream rather than on `conversation.runtime` also means a
conversation whose flag flipped between turns renders its earlier turns
through the legacy parser and its later ones through ACP, which is the A/B on
one screen the gate asked for.

Three things the build settled that the ADR had only asserted:

- **The turn really does have two terminators, and they are not symmetric.**
  The stop reason arrives first and closes stdin; the process exit follows and
  must be a no-op. Clearing `current_command_ref` is what makes it one — the
  existing `{:exit, …}` clause then finds no match and falls through. A test
  asserts the turn stays `completed` when an exit code of 1 arrives after a
  successful stop reason, because the alternative is a finished turn being
  overwritten by the adapter's exit status.

- **`session/request_permission` had to be answered in gate 2, before the gate
  that is about answering it.** An unanswered request blocks the agent, and a
  blocked agent is a turn in flight — which disarms idle reclaim and bills the
  sprite to the ceiling, the same shape as #413. Gate 2 auto-allows, which is
  exact parity with the `--dangerously-skip-permissions` the legacy path
  already passes. Gate 3 replaces the answer source, not the plumbing.

- **`fs/*` and `terminal/*` are refused, not ignored.** We declare no client
  filesystem or terminal capability, so a well-behaved adapter never asks; one
  that asks anyway gets JSON-RPC `-32601`. Silence would hang the agent.

Images and MCP servers travel over the protocol rather than around it.
Attachments are `image` content blocks inside `session/prompt`, so the legacy
dance — write the bytes into the sandbox, append the paths to the prompt, hope
the model reaches for its Read tool — is skipped entirely on this path. MCP
servers are passed to `session/new` and re-sent on every resumption, because
the adapter snapshots `{cwd, mcpServers}` per session and tears the session
down when that snapshot changes; omitting them on resume reads as *the client
removed every MCP server*. They are still installed into the sandbox by
`Claude.prepare_sprite/3` as well — belt and braces, since gate 1 could not
confirm that an SDK-based adapter reads the CLI's user-scope config.

Two shape details that fail silently rather than loudly, both taken from the
pinned adapter's own parser rather than from prose: `env` and `headers` are
arrays of `%{name, value}` and **not** maps (a map is valid JSON and reads as
nothing, so the server starts with no environment and surfaces later as a tool
that cannot authenticate); and a stdio server carries **no** `type` key at all,
because the adapter routes anything with a `type` down its http/sse branch and
looks for a `url` that is not there.

#### Measured against live sprites — 2026-08-10

The pinned adapter, installed by `ACP.install/2` into real sprites, driven over
its stdio. Two runs, four turns; small enough that these are indicative
magnitudes rather than a benchmark.

**The capability read from gate 1 holds against the running binary.**
`agentInfo` reports `@agentclientprotocol/claude-agent-acp` `0.66.0`,
`loadSession: true`, and `sessionCapabilities` containing `resume` alongside
`additionalDirectories`, `close`, `delete`, `fork` and `list`. `--version`
prints a bare `0.66.0`, so the install's idempotency check compares cleanly.

| | measured |
|---|---|
| `ACP.install/2`, cold | 11.2 s (once per sprite, at provision) |
| handshake — spawn → `initialize` response | 0.37 s – 1.22 s |
| `session/new` | 0.80 s |
| `session/resume` | 1.31 s – 1.37 s |
| `session/prompt` (a one-token reply) | 1.69 s – 2.97 s |
| **ACP turn, end to end** | **3.7 s / 5.6 s** |
| **legacy `claude --print` turn, same prompt** | **4.6 s** (of which the CLI self-reports 2.1 s of work) |

So the per-turn protocol overhead — `initialize` plus session setup, roughly
2.0–2.6 s — lands in the same range as the legacy CLI's own startup, about
2.5 s by subtraction. **End to end the ACP turn was not slower than the turn it
replaces**, which is the comparison gate 2 asked for. The turn-scoped
connection does not need the sandbox-scoped escape hatch, and that option stays
unexercised rather than being taken pre-emptively.

Two things the run found that no test could:

- **`npm install -g` does not put the adapter on `PATH`.** `npm prefix -g` is
  `/.sprite/languages/node/nvm/versions/node/v24.18.0`, and its `bin/` is not
  in the sprite's default `PATH`, so a spawn would have failed with `command
  not found` — an error that reads like a protocol bug and is not one. Fixed by
  symlinking into `/home/sprite/.local/bin`, the same way `OpenCode`'s
  installer already works around the identical problem with bun.

- **A resumed session survives the process, exactly as designed.** Turn 2 ran
  as a *separate connection* to the same sprite — new process, new
  `initialize`, `session/resume` with the persisted id — and the agent
  correctly answered a question that only turn 1's context contained. The
  turn-scoped connection is sound.

Everything the ACP path carries over the protocol rather than around it was
then exercised against the same adapter, using the shapes the production code
actually emits:

- **MCP servers arrive, and `env` really is an array.** A stdio server passed
  through `ACP.mcp_servers/1` into `session/new` was started, listed and
  called; its tool returned a value read from `MCP_TEST_VAR`, which was
  delivered exactly as the `[%{name:, value:}]` form predicted. That was the
  riskiest guess in the mapping — a map would have been accepted as JSON and
  silently produced an empty environment — and it is now a measured fact
  rather than a reading of the adapter's source.

- **`session/request_permission` is real, and gate 2 was right to answer it.**
  The MCP tool call produced exactly one permission request. Had the peer not
  replied, the agent would have blocked — a turn in flight, idle reclaim
  disarmed, the sprite billing to its ceiling. The channel gate 3 is built on
  demonstrably exists on this adapter.

- **Images in `session/prompt` work.** A generated PNG sent as an `image`
  content block was described correctly, so attachments survive the ACP path.

- **Skills are discovered from the CLI's tree**, resolving gate 1's open
  question above.

#### The reclaim finding, which is bigger than this gate

**A session does not survive its sandbox, and that was already true before
ACP.** Destroying the sprite and resuming on a fresh one — precisely what
`Lifecycle` reclaim plus `wake_conversation`'s `:create_new` branch does, down
to the new sprite name — fails on *both* paths:

- ACP: `session/resume` returns `-32002 Resource not found: <session id>`.
- Legacy: `claude --resume <id>` prints `No conversation found with session ID`
  and exits with `error_during_execution`.

The session lives in the sandbox's filesystem. The environment checkpoint that
a fresh provision restores is taken at *provision* time, before any turn, so it
cannot contain it.

This falsifies a claim made above, in *Session lifetime*, and inherited from
`Lifecycle`'s own docstring: that "the cost of reclaiming early is a
re-provision on the next prompt, not lost work." The cost is the agent's
memory of the conversation. Fountain's transcript is unaffected — `log_events`
still render every turn — so the failure is silent and asymmetric: the user
sees their history, the agent does not have it, and
`Lifecycle.explain/1` tells them "history is preserved — send another prompt to
continue."

That is a pre-existing defect rather than an ACP one, and it is tracked
separately. What it changes *here* is the reasoning: the turn-scoped connection
is still correct and still cheap, but it is no longer justified by reclaim
being harmless, because reclaim is not harmless. It is justified by reclaim
being *unavoidable* — sandboxes are bounded whatever the protocol does — and by
ACP at least failing loudly, with a session id it was actually asked for,
where the legacy path fails on an id it guessed.

> **Correction, 2026-08-13 ([decisions/0017](0017-suspend-idle-sandboxes.md)).** The idle bound no longer
> destroys the sprite: an idle sandbox is *suspended* — the sprite stays,
> scaled to zero, and the next prompt reattaches to the same disk, so the
> session survives and this section's failure mode applies only to the
> max-lifetime ceiling (and to explicit termination). The premise this ADR
> inherited from `Lifecycle` — that an idle sprite bills until destroyed —
> was itself wrong; sprites stop billing on their own. The turn-scoped
> connection stays correct on 0017's terms too: nothing is attached between
> turns, whether the sandbox is parked or destroyed.

> **Correction, 2026-08-18 (#778).** The *loud* failure is gone too. A
> `ConversationServer` that provisions a fresh sandbox now clears
> `runtime_session_id` (`forget_runtime_session/2`) and publishes a `session`
> stage event (`event: reset, reason: fresh_sandbox`), so the next turn is
> `session/new` on the new disk rather than a `session/resume` that fails
> `-32002` on every prompt until the conversation is terminated. The agent's
> memory is still lost when its sandbox is — that is unchanged — but the
> conversation keeps working and the transcript says why.

### Gate 3 — permissions — **not built**

> **Rewritten 2026-08-21.** As drafted this gate said "implement
> `session/request_permission` against the conversation LiveView". That
> LiveView no longer exists — conversations and team are separate apps served
> over the API (#865-#870) — and the request half is already built
> (`peer.ex:372`). What follows replaces the original text, which claimed a
> channel had to be created when what it needs is a policy and a door.

Tracked as #643, split into #939 (the policy), #940 (the ask path) and #941
(gemini's remaining flag).

**The policy.** A per-tool permission map — `auto_allow` / `auto_deny` / `ask`
— held on the agent and resolvable per launch, the shape `environment_id` took
in #783. **A launch may narrow the agent's map; it may never widen it.** That
single rule is what keeps a launch-time override from being an escalation
path, and it is why no `allowed_*` list is needed alongside it. The global
default stays `auto_allow`, so adopting the policy changes no existing
conversation's behaviour.

`auto_deny` selects a `reject_*` option when the agent offered one and
`cancelled` when it did not. **Never synthesise an option the agent did not
offer** — what a given adapter does on `cancelled` differs, and must be
measured per adapter rather than assumed.

**The wire.** The request surfaces as a `permission_request` **block** on the
`acp` stream, so it renders inline in the transcript through the pipeline
clients already run (`Blocks.for_event/2`); the resolution is a **stage
event** (`stage: "request"`, `state: "done"`, verdict in `data`), because log
events are immutable and resolution is the operationally meaningful
transition the stage counter should see. Clients pair the two on `request_id`,
exactly as they already pair `tool_result` to `tool_use` on `tool_id`. This
needs no change to the closed `state` enum.

**What answers when nobody is watching.** A permission timeout, defaulting
well under `idle_timeout_seconds`, whose expiry is **deny**. The alternative —
reporting a blocked turn as `busy?: false` so idle reclaim catches it — was
rejected: it lies about busyness, and suspending a sandbox mid-request is its
own failure. This matters more than the original text knew. `Lifecycle.check/4`
suppresses only the *idle* verdict when busy, so a blocked turn today sails
past the idle bound and is resolved by the ceiling — and per 0017 the idle
bound suspends while the ceiling **destroys**. Left alone, an unanswered
prompt does not hang forever; it burns the maximum lifetime and then takes the
agent's memory with it (#649).

**Survival across a restart.** The JSON-RPC request id lives in the peer and
dies with it, so a request minted before a deploy cannot be answered after one
unless the id is persisted the way `acp_prompt_id` already is — the same trap
`attempt_session_attach` orphans a turn for today
(`conversation_server.ex:1005`), and the one #772 was.

**Audit.** Denials and policy changes are recorded, per 0013 — in the context,
tool and verdict only, never values. Allows are not: a turn makes dozens of
tool calls, and a row per allow would make the trail a transcript.

**Not permitted:** a sprite answering its own permission request. It holds a
`FOUNTAIN_TOKEN`, and that loop is closed by name rather than by accident.

If this gate turns out to be blocked — by adapter support, by latency, by the
reaper killing sessions mid-prompt — the honest outcome is to say so here. It
is no longer a reason to stop the campaign; gates 2 and 4 have already paid
for it.

### Gate 4 — remaining runtimes, and parser deletion — **in progress**

> **Amendment, 2026-08-13.** Two changes to this gate as written. First, the
> sequencing: #644 already departed from "only after gate 3" — if the
> justification is deleting per-runtime code, permissions follow the
> conversions rather than gating them, and this amendment makes the ADR match
> the tracker. Second, the default: ACP is now **on by default** for the three
> shippable runtimes. `enabled?/1` reads `metadata["acp"] != false`, so the
> flag is an operational opt-out (routing around a broken adapter release
> without a deploy), no longer an experiment's opt-in. The deletion rule below
> is unchanged: a parser is deleted when its runtime's ACP path has served
> real conversations, and default-on is what makes that happen.

A parser is deleted when its runtime's ACP path has served real conversations,
not when the code compiles.

> **Amendment, 2026-08-14.** The render path is clean: the four dialect
> parsers left the LiveView for a dedicated `LegacyBlocks` module (#642).
> Three of them are *frozen*, not deleted — the converted runtimes' `stdout`
> rows predate ACP and still need rendering, but the input set is historical
> and can no longer change, so the maintenance surface this gate exists to
> shed is gone. They are deleted outright when pre-ACP history ages out of
> retention. `pair_tool_results/1` also survives, deliberately: the ACP
> translation leans on it to collapse `tool_call`/`tool_call_update` block
> pairs, which is cheaper than a second pairing pass.

**Three of the four runtimes are converted and one is not, for a reason
outside our code — 2026-08-11.** Claude, Codex and OpenCode each did
`session/new` then `session/resume` against a live agent, recalling a token
only the prior turn established. Gemini's first turn is equally good and its
resume cannot be made to work from this side, so it is excluded from
`ACP.supported_runtimes/0` (#659) and its dialect parser stays.

The mechanism, read out of gemini 0.53.0's shipped bundle and confirmed on live
sprites (#658): a session **is** written to disk after turn 1, and gemini's own
`--list-sessions` finds it. `session/load` then builds a fresh config on the
same session id *before* resolving the session, and that config's chat recorder
takes its new-session branch — computing the same file name, which is the first
8 characters of the session id plus the current wall-clock **minute**, and
appending a `$set` whose `messages` array holds only its `<session_context>`
bootstrap. The reader treats `$set.messages` as a replacement and skips
`<session_context>` as ignored content, so the session it was asked to load now
has no resumable content, disappears from the listing, and comes back as
`-32603` "No previous sessions found for this project".

Two consequences worth carrying into gate 4:

- **The intermittency was a clock.** A resume in the same minute as the
  previous turn always fails; one a minute later lands its poison in a sibling
  file and succeeds. The earlier "2 successes to 4 failures" was not a race.
  Waiting is still not a workaround — a *second* consecutive resume failed with
  a minute between every turn, and afterwards every older session file for that
  project had been removed. One resume is not a conversation.
- **Failure is destructive.** The session is unloadable afterwards, so this
  costs a conversation rather than a turn — which is the whole reason the flag
  must not reach gemini, rather than merely being discouraged for it.

A workaround would mean writing into another product's private store on a
filename convention it can change without notice. We wait for upstream.

### Not in scope

Fountain as an ACP **agent** — `cli/` speaking ACP so that an editor could
drive a Fountain conversation running in a remote sandbox. That is
[0015](0015-fountain-as-an-acp-agent.md), and it is deliberately a separate
decision: it is a distribution question rather than an architectural one, and
it must not influence the gates above.

The sequencing runs the other way, though. 0015 is *gated on this ADR*,
because the event stream it would build on forwards raw runtime stdout — an
ACP agent on today's API would have to reimplement the four dialect parsers in
Go. Once gate 2 here lands, Fountain is already holding ACP blocks and the
editor-facing side forwards rather than translates. Fountain becomes an ACP
proxy, and the dialects stop at the server boundary, which is the only place
that knows which runtime produced them.

## Consequences

**We take on a JSON-RPC peer.** Bidirectional, with request/response
correlation, agent→client method dispatch and cancellation
(`session/cancel` is a notification with no reply). This is a new GenServer
sitting beside a `ConversationServer` that is already 2,088 lines. If the
peer lands inside that module, this ADR has been implemented wrongly.

**A turn now has protocol state, even though the connection does not
outlive it.** *Session lifetime* above settles the reaper question — nothing
is attached between turns, so `SandboxReaper`, the rehydrator and `Lifecycle`
are unchanged. What remains is that the turn itself is no longer a process we
watch for an exit: it is a connection with states (initialised, prompting,
awaiting a permission answer, cancelled) and two ways to end. The failure mode
does not go away, it changes shape — from a runtime that exits without saying
why, to a peer that is waiting for a message that will never arrive. Both end
as a sprite billing until `max_lifetime`; the second is harder to see.

**Client-side methods point at the wrong filesystem.** `fs/read_text_file`,
`fs/write_text_file` and `terminal/*` are implemented by the *client*. Ours
would have to service them against the **sprite**, not the Fountain server —
via `Sprites.cmd`, with tenant scoping that the protocol knows nothing about.
This is where the abstraction leaks, and it is the part most likely to
produce a security finding if implemented carelessly. Absolute-path and
1-based-line requirements are the protocol's, not ours; a path arriving over
this channel is untrusted input from a sandbox we do not fully control.

**We gain a supply-chain surface.** Some runtimes will need a Node adapter
package baked into the sprite image, versioned independently of the CLI it
wraps and lagging it. `hex.audit` does not see these. Whatever we vendor gets
pinned and shows up in the image build.

**What we give up:** a small, dumb, legible spawn path. `build_command/5`
returning argv is trivially testable and fails loudly. A live protocol
session has states — initialised, authenticated, prompting, cancelled — and
therefore has state bugs. The bet is that permission prompts plus explicit
session ids are worth that, and gate 3 is where the bet is settled.

## Alternatives considered

- **Keep hand-writing parsers.** Honest option, and correct if we stay at four
  runtimes forever. Rejected because it cannot produce a permission prompt at
  any price, and because the parsers live in the render path where a vendor's
  point release becomes our rendering bug.
- **Normalise to our own internal event schema, no ACP.** Same render-path
  win, no protocol dependency, no adapter supply chain. Rejected because it is
  strictly more work than adopting a spec that four vendors already target,
  and it still leaves permissions unreachable — the translation would be from
  the same one-way streams we have now.
- **Full cutover to ACP in one change.** Rejected: it would couple a protocol
  migration, a process-lifetime change and a reaper change in one PR, across
  four runtimes, with the LiveView moving underneath it.
- **Fountain as an ACP agent first.** More strategically interesting and
  answers a real distribution question, but it does nothing for the four
  parsers or the permission gap — and building it first would mean a second
  copy of those parsers in Go. Split out as
  [0015](0015-fountain-as-an-acp-agent.md), sequenced after this.
