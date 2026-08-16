---
type: ADR
title: "Fountain as an ACP agent, reachable from a code editor"
description: "fountain acp speaks ACP over stdio to an editor and HTTP+SSE to the API, so an editor can drive a Fountain agent. Gates 1 through 3 built; gate 4 (permission forwarding) not built."
tags: [acp, cli, editor]
status: stable
adr: "0015"
adr_status: "Accepted"
date: 2026-08-09
generated: { by: human:jhgaylor, at: 2026-08-14T22:24:48-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-14T22:24:48-04:00 }
stale_after: 2026-11-14
---

# 0015 — Fountain as an ACP agent, reachable from a code editor

**Status:** Accepted — **gates 1–3 are built.** `fountain acp` exists in
`cli/internal/acp`, and an editor can open a conversation on a Fountain agent,
prompt it, watch it stream, cancel it, and reopen it later
([#709](https://github.com/BinaryBourbon/fountain/issues/709): gate 1 in
#710/#711/#712, gate 2 in #713/#714/#715, gate 3 in #718 and the PR carrying
this line). **Gate 4 — permission forwarding — is not built** and remains
blocked on #643; the *Consequences* section below states what it needs first.

This is the second of two ADRs about the Agent Client Protocol and covers the
opposite direction from [0014](0014-agent-client-protocol.md).

What the build changed about the design as written, all recorded in the gates
below: the ACP session id **is** the conversation id rather than a minted one,
because an editor must be able to hand back an id from last week; the sandbox
paths in `tool_call.locations` are removed rather than labelled, because the
protocol has no way to say "this path is on another machine"; and the adapter
turned out to be a forwarder rather than a translator, which is the best case
this ADR hoped for from 0014 and the reason it stayed small.

## Context

[0014](0014-agent-client-protocol.md) proposes Fountain as an ACP **client**,
talking to the coding-agent CLIs it already runs inside sprites. This ADR is
about the other end: making a Fountain conversation reachable from an editor,
with Fountain itself as the ACP **agent**.

The two are complements, not alternatives. Taken together they make Fountain
an **ACP proxy** — the same block vocabulary arriving from a sprite on one
side and leaving for an editor on the other. That symmetry is the central
insight of this ADR, and it is also the source of its one hard dependency
(see *Dependency on 0014*).

### The shape, drawn

This ADR is the upper half of the picture; [0014](0014-agent-client-protocol.md)
is the lower half. Both are drawn here so that neither is read as a tree with
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

Three things the boxes are there to make hard to misread.

**`fountain acp` is a local subprocess of the editor, not a network peer of
the server.** The editor spawns it and speaks ACP down a pipe; the HTTP+SSE
hop happens on the far side of that process. This is where authentication and
multi-account selection stay, and it is why the remote transport is declined
below rather than treated as the obvious future.

**The web UI is a peer client, not a legacy one.** Two surfaces render the
same conversation from the same stream — that is the *Team visibility* bullet
below, and it is also why the stream picks up interface obligations under
*Consequences*.

**The workspace is at the bottom of the diagram.** The editor is the only box
on it that has no files in play. Any picture that runs a line straight from an
editor to a remote agent invites exactly the misreading that
*the impedance mismatch* section exists to prevent, and that v1 answers by
declaring no client `fs/*` or `terminal/*` capabilities at all.

Placement — which sandbox platform runs the sprite, and in whose cloud — is
deliberately absent. It is an axis neither ADR touches: ACP unifies the leaves,
not the substrate.

### Why an editor would want this rather than a local agent

An editor can already spawn Claude Code or Codex locally. Fountain is worth
reaching for only where a local subprocess cannot go, and there are five
places:

- **The work outlives the editor.** `ConversationServer` and the rehydrator
  already keep a turn running when nothing is attached. Close the laptop, the
  turn continues; reopen, reattach.
- **Conversations are addressable and persistent.** A transcript, turn
  history, and an audit trail (0013) that outlive any editor session.
- **Fan-out.** `X-Fountain-Parent-Conversation-Id` and
  `GET /api/conversations/:id/tree` mean one editor session can start and
  enumerate N sub-conversations. No local agent subprocess does this.
- **The unit is a Fountain agent, not a raw CLI.** The editor picks something
  that already has an environment, vault overrides, skills and MCP servers
  provisioned — and inference credentials that never touch the developer's
  machine.
- **Team visibility.** The same conversation is open in the web UI for anyone
  with access, while it runs.

### What already exists to build on

The Go CLI (`cli/`, ~5.5k lines) is already an HTTP+SSE client for exactly
this API, with the hard parts done:

- `GET /api/conversations/:conversation_id/stream` is a real SSE endpoint —
  resumable via `Last-Event-ID`, heartbeated, filterable by `?streams=`, and
  it publishes a terminal stage when a conversation server dies rather than
  heartbeating into the void (`conversation_controller.ex:495-650`).
- `cli/internal/cmd/stream.go` already consumes it with reconnect, backoff and
  idle-timeout handling, and already classifies terminal outcomes
  (`errTurnFailed`, `errProvisionFailed`, `errSandboxExpired`) — which is
  precisely the classification an ACP stop reason needs.
- `fountain auth login` and `~/.fountain/credentials` already solve
  authentication.
- `cli-release-go.yml` already ships four platform binaries per tag.

Adding one subcommand to a binary that is already installed, authenticated and
distributed is a materially smaller proposition than anything in 0014.

### The impedance mismatch, which is the whole design problem

ACP assumes the agent runs as a subprocess of the editor and edits **the
editor's** files — that is why `fs/read_text_file` and `fs/write_text_file`
are *client*-provided (so the agent sees unsaved buffer state), and why
`tool_call.locations` exists for the editor to follow along.

A Fountain agent edits a **sprite's** filesystem, on a repo the sprite cloned.
The developer's working copy is a different machine. Every design that
pretends otherwise produces an agent that appears to be editing the open
project and is not.

## Decision

Build **`fountain acp`**: a subcommand of the existing Go binary that speaks
ACP over stdio to an editor and HTTP+SSE to the Fountain API. The editor
spawns it exactly as it spawns any other ACP agent.

Deliberately *not* ACP's remote (HTTP/WebSocket) transport, which the protocol
introduction documents as work in progress. Local stdio is the stable,
universally implemented transport; it needs no inbound network path to the
developer's machine, and it puts authentication in the one place that already
handles it. Confirm the remote transport's status at build time, but do not
design for it.

### The workspace question: a control surface, not a workspace

**v1 declares no client filesystem or terminal capabilities and requests
none.** The editor is where you watch, steer, interrupt and fan out a remote
conversation — not where its files live. `tool_call.locations` are emitted as
explicitly sprite-side paths, labelled as such, so an editor cannot mistake
them for local ones.

This is a real product limit, stated rather than hidden. The two escalations
past it are separate decisions and must not be smuggled in through a protocol
adapter:

- **Read-through** — the editor opens a file the agent touched. Needs a new
  server endpoint to read a file out of a sandbox (`POST /api/conversations/
  :id/read` is mark-as-read, not file read — nothing like this exists today),
  plus tenant scoping and a path-traversal story for paths that arrive from a
  sandbox we do not fully control.
- **Workspace sync** — mirroring the local checkout into the sprite and diffs
  back. This is Fountain becoming a remote-development product. It deserves
  its own ADR and its own answer to "what happens on conflict".

### Protocol mapping

| ACP | Fountain |
|---|---|
| `initialize` | capability declaration; `authMethods` points at `fountain auth login` |
| `authenticate` | existing API key from `~/.fountain/credentials` |
| `session/new` | `POST /api/conversations` for a chosen agent |
| `session/load` | replay `GET .../stream` from `Last-Event-ID: 0` |
| `session/prompt` | `POST .../prompts`, then block on the stream until a terminal stage |
| `session/update` | translated stream events (see below) |
| `session/cancel` | `POST .../interrupt` |
| stop reason | the terminal-outcome classification `stream.go` already computes |

`session/prompt` must block and return a stop reason, while Fountain's API is
post-then-stream. The adapter therefore correlates the prompt response with
the terminal stage event on the SSE stream — the same correlation `stream.go`
performs today to give `fountain run` a truthful exit code (#398).

### Dependency on 0014

**The SSE stream carries raw runtime stdout.** `LogEvent.data` is the CLI's
own stream-json, forwarded verbatim (`conversation_controller.ex` `write_event`
over `_unsafe_list_log_events`). So an ACP agent built on today's API would
have to parse four proprietary dialects to emit `session/update` — and those
parsers already exist, in Elixir, in a LiveView (`show.ex:1340-1530`).

Writing a second copy in Go is the one outcome this ADR exists to prevent: two
implementations of four undocumented formats, in two languages, drifting.

So this work is **gated on normalization happening server-side**, which is
what 0014 produces. In the best case it is nearly free: once Fountain is an
ACP client of the sprite, it is holding ACP blocks already, and
`fountain acp` forwards rather than translates. Fountain becomes a proxy and
the dialects stop at the server boundary — which is exactly where they should
stop, since that is the only place that knows which runtime produced them.

If 0014 stalls, the fallback is a normalized event kind on the stream
(`?streams=blocks`) emitted by the server from the same Elixir parsers. Either
way the translation happens once, in Elixir. **A dialect parser must never
land in `cli/`.**

### Gates

1. ~~**Transcript-only prototype, one runtime.**~~ **Built.** `fountain acp`
   renders a live remote conversation: message chunks, thoughts, tool calls
   with status. No `fs/*`, no `terminal/*`. Verified against prod, not only in
   tests — the run returned a tool call and a real stop reason.
2. ~~**Session lifecycle.**~~ **Built.** `session/load`, `session/cancel`,
   stop reasons taken from the sandbox's own adapter, and survival across a
   dropped SSE connection. Verified live: a cancel answered a blocked prompt
   with `cancelled` in 0.1s, and a load replayed 31 updates before responding.
3. ~~**Auth and distribution.**~~ **Built.** `authMethods`, the editor page in
   `docs/integrations/editors.md`, and the event stream documented as the
   interface it now is (#707).
4. **Permission forwarding** — not built, blocked on 0014 gate 3 (#643). See
   below.

**Two things found by running gates 1–3 against production, which the tests
could not see.** Both are worth keeping here because they are properties of
this design, not accidents. The filtered *replay* of the event stream had
never included the `acp` stream, so `session/load` returned an empty
transcript and every mid-turn reconnect silently dropped what it missed
(#716) — a proxy that forwards stored events depends on the store's filter as
much as on the protocol. And a lost wake race leaves a conversation pointing
at a sandbox it just terminated (#717), which this adapter reproduces on every
session because `session/new` and the first `session/prompt` arrive a second
apart.

**On the remote transport, which this gate said to revisit:** ACP's own
introduction still documents it as work in progress, and nothing in the build
argued for waiting. The local process kept earning its place — it is where
`fountain auth login`'s credentials already are, and where the instance and
profile are chosen.

## Consequences

**Permission requests would traverse two hops.** If 0014 gate 3 lands, a
`session/request_permission` originating in the sprite has to be forwarded
editor-ward and answered back down: sprite → Fountain → editor → Fountain →
sprite. That needs a timeout policy and an answer to *what replies when the
editor detaches mid-request*. A conversation blocked forever on a permission
prompt nobody will ever see is a new failure mode, and neither `SandboxReaper`
nor the rehydrator knows about it. Do not start gate 4 without that answer.

**Two clients now depend on the event stream's shape.** The web UI and the ACP
adapter would render from the same normalized events. That is the point — but
it means the stream stops being an implementation detail of `show.ex` and
becomes an interface, with the compatibility obligations of one. It belongs in
the OpenAPI spec and under the router-walking guard test added by the #531
campaign.

**We would be shipping an editor integration, with editor bug reports.** ACP
clients differ in what they render and how they handle a slow agent. Support
surface grows in a direction the team has no experience with, and "it doesn't
work in $EDITOR" lands in our tracker regardless of whose bug it is.

**The stdio proxy is not throwaway work.** Even if ACP's remote transport
stabilises and editors can point at a URL, the local process is where
credentials, workspace policy and multi-account selection live. It stays.

**What we give up:** the simplicity of Fountain having exactly one interactive
surface. Today the web UI is the product; the CLI is a script tool. An editor
integration is a third first-class surface with its own expectations about
latency and interactivity — a conversation that takes four seconds to
provision a sandbox reads very differently inside an editor than on a web page
that showed a spinner and a log.

## Alternatives considered

- **Do nothing; keep the web UI as the only interactive surface.** Defensible.
  Rejected as the default because the editor is where the developer already
  is, and every advantage listed above is one Fountain already has built and
  currently exposes only through a browser tab.
- **Wait for ACP's remote transport and expose ACP directly from Phoenix.**
  Removes the local binary entirely and is architecturally cleaner. Rejected
  as a *starting point*: the transport is documented as WIP, and it would put
  auth and multi-account selection into the protocol layer rather than into
  the CLI that already solves both. Revisit at gate 3.
- **A bespoke editor extension per editor.** Maximum control, and the way to
  get true workspace sync. Rejected: it is the N×M problem ACP exists to
  delete, and we would be paying it from the wrong side after arguing the
  opposite in 0014.
- **Build this before 0014.** Tempting — it is smaller, more visible, and the
  CLI already does most of it. Rejected because the only way to emit
  `session/update` from today's API is to reimplement four dialect parsers in
  Go, which is strictly worse than the status quo it would be fixing.
