# 0014 — Speaking the Agent Client Protocol to runtimes

**Status:** Proposed — **nothing described here is built.** No ACP code exists
in this repo today. This ADR records a direction and the gates that decide
whether we take it; the PR that builds each gate removes its caveat.

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

### Gate 1 — survey, no code

Confirm per runtime how ACP support is actually provided and what the version
floor is. Claude Code and Codex are documented as supported via Zed's adapter
packages (`zed-industries/claude-agent-acp`, `zed-industries/codex-acp`).
Gemini CLI and OpenCode are both listed as ACP-supporting, but the published
agents page does not clearly separate native support from adapter-based
support — **resolve this before choosing the spike runtime**, because a
runtime needing a vendored Node adapter in the sprite image is a materially
different proposition from one that speaks ACP with a flag.

Deliverable: a table of runtime → mechanism → package (if any) → minimum
version, and a recommendation for which single runtime to spike.

### Gate 2 — one runtime, behind a per-agent flag

Build `Fountain.Runtimes.ACP` as a JSON-RPC peer over the stdio pipe we
already own (`Fountain.SpriteStdin.write/2` for the write half, the existing
stdout tail for the read half), for exactly one runtime, selected by gate 1.
Leading candidate is Gemini — not for protocol reasons but because its resume
semantics are the weakest thing we ship, so the spike fixes a live hazard
rather than only relocating code.

The peer must translate `session/update` into **the same block maps
`show.ex` already renders**. The LiveView does not change in this gate. That
constraint is what makes the two paths A/B-able on one screen, and it is the
only way we find out whether the ACP stream is actually richer or merely
different.

Ship it off by default, enabled per agent, with the legacy path intact.

### Gate 3 — permissions

Implement `session/request_permission` against the conversation LiveView: a
real approval prompt, per tool call, with the answer written back over the
same connection. This is the gate that justifies the project. If gates 1-2
land and gate 3 turns out to be blocked — by adapter support, by latency, by
the reaper killing sessions mid-prompt — the honest outcome is to stop with
one runtime converted and say so here.

### Gate 4 — remaining runtimes, and parser deletion

Only after gate 3 holds in production. A parser is deleted when its runtime's
ACP path has served real conversations, not when the code compiles.

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

**The connection outlives the turn.** Today we spawn a process per turn and
resume; ACP wants one connection alive for the session. That interacts
directly with `SandboxReaper` and the rehydrator, which are built around the
assumption that nothing is attached between turns. A reconnect story is
mandatory, not a follow-up: where an adapter implements `session/load` we use
it, and where it does not we are back to the same guess-the-session resume
we started with — which is a reason to reject that runtime for conversion,
not a reason to paper over it.

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
