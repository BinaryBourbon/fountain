# Managoat.ACP

The client side of the [Agent Client Protocol](https://agentclientprotocol.com),
as a session that outlives the turn. ACP is JSON-RPC 2.0 over newline-delimited
JSON between a *client* (an editor, or a platform that runs agents for people)
and an *agent* (claude-agent-acp, codex-acp, gemini, opencode). This package is
the client: the peer that drives the handshake and the prompt, answers the
agent's requests, keeps a permission request open for a human, reattaches to a
turn that is still running after the client restarted, and reports everything
to an owner process as plain messages. Plus the pieces a real deployment needs
around it: a permission policy, block normalisation for rendering, usage
accounting, and an OpenTelemetry tracer.

It is not a schema library. Messages are maps with the protocol's own wire
names, and what the package adds is the part of a client the spec leaves to
you. See [How this relates to acpex and agent_client_protocol](#how-this-relates-to-acpex-and-agent_client_protocol)
for the comparison and the recommendation.

```elixir
# A writer is the whole transport: one function, bytes out.
writer = fn iodata -> Managoat.Sandbox.write_stdin(command, iodata) end

{:ok, peer} =
  Managoat.ACP.Peer.start(
    owner: self(),
    writer: writer,
    ref: command.ref,
    prompt: "run the tests and fix what fails",
    mode: :run,
    session_id: nil,
    cwd: "/home/sprite",
    mcp_servers: [%{name: "fs", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "."]}],
    model: "claude-sonnet-4-6",
    permission_policy: %{"default" => "auto_allow", "execute" => "ask"}
  )

# Bytes in: from wherever the host's bytes arrive.
def handle_info({:stdout, %{ref: ref}, data}, state), do: Managoat.ACP.Peer.stdout(state.peer, data)

# Reports: every one is {:acp, ref, payload}.
def handle_info({:acp, ref, {:session, id}}, state), do: persist_session_id(id)
def handle_info({:acp, ref, {:lines, "acp", line}}, state), do: persist_line(line)
def handle_info({:acp, ref, {:permission_ask, request_id, tool, options}}, state), do: ask_a_human(...)
def handle_info({:acp, ref, {:done, stop_reason, usage}}, state), do: close_turn(stop_reason, usage)

# The next turn rides the same connection: no handshake, no resume.
:ok = Managoat.ACP.Peer.prompt(peer, "now open a PR")
```

## The pieces

| Module | Role |
|---|---|
| `Managoat.ACP.Peer` | One connection, for as many turns as its owner sends it. `initialize` → `session/new` / `session/resume` / `session/load` → `session/prompt`; then `:idle`, where `prompt/3` sends the next turn on the same session. Answers `session/request_permission` from the policy, refuses `fs/*` and `terminal/*` (the client declares neither), authenticates when the agent offers an api-key method, pins the model through whichever of `session/set_config_option` and `session/set_model` the agent advertises. |
| `Managoat.ACP.Transport` | The seam. A `writer :: (iodata -> :ok \| {:error, term})` for outbound frames; inbound bytes go through `Peer.stdout/2`. Not a behaviour, not a process. |
| `Managoat.ACP.Protocol` | Framing (`feed/2` carries the partial tail across chunks), classification, encoding, `initialize_params/1`. Pure. |
| `Managoat.ACP.Permissions` | The policy map and what it answers: `auto_allow`, `ask`, `auto_deny` per tool title, per ACP `kind`, or by default; most-specific-first matching; `effective/2` clamps a launch's policy to be no looser than the agent's; `deny_outcome/1` refuses from the options the agent offered and never invents one. |
| `Managoat.ACP.Blocks` | `session/update` notifications and permission requests as the block maps a transcript renders. |
| `Managoat.ACP.Usage` | The end-of-turn token figure, normalised from the `session/prompt` result's `usage` (or `_meta`). |
| `Managoat.ACP.Tracer` | `tool_call` / `tool_call_update` as child spans of a turn span, with byte counts for text and thinking. Only the OpenTelemetry API is a dependency; with no SDK started, every call is a no-op. |
| `Managoat.ACP.Testing.ScriptedAgent` | An agent inside the BEAM: answers the handshake, streams scripted updates, asks for a permission when told to. Ships in `lib/` so a host's tests can drive a real peer without a sandbox or a stub. |

## The transport is a callback

The peer's contract with the outside world is "bytes out by function, bytes in
by cast". It takes a `writer` at start and is fed inbound bytes through
`Peer.stdout/2` from wherever the host's bytes come from — a sandbox owner
forwards the sandbox's stdout message, a stdio host forwards a `Port` message,
a test feeds a scripted reply. The library ships no transport, on purpose:
every transport the peer has run over is push-shaped on the read side, so a
behaviour with a `read` callback would be pretending to a symmetry that is not
there, and a transport process would tie the peer's lifetime to it.

The writer must be **total**. A transport that has gone away answers
`{:error, reason}`; the peer reports it once as
`{:failed, {:acp_write_failed, reason}}` and stops writing. A writer that
raised or exited instead would take the peer down without a report, and for a
turn in flight that is a turn with no terminator.

The `ref` passed at start is echoed in every report, so an owner that runs
several peers (or restarts one) matches on it and ignores a stale peer's
messages without a second registry.

## What the owner receives

Every message is `{:acp, ref, payload}`. The peer persists nothing and writes
nothing but protocol; these are the whole contract.

| Payload | When | What an owner does with it |
|---|---|---|
| `{:lines, stream, data}` | a `session/update` arrives (`"acp"`); a non-JSON line arrives (`"stdout"`); the peer has a note of its own (`"stderr"`, one case: the runtime exposes no model selection) | Persist `data` as one line on `stream`. The `"acp"` line is the raw notification, so a transcript can be rendered from storage with `Blocks.from_line/1`. `Protocol.session_metadata?/1` tells a title or command-list update from agent activity, for an owner that treats out-of-turn activity as its own turn. |
| `{:session, id}` | `session/new` answered | Persist as the durable session id; hand it back as `session_id:` with `mode: :continue` on the next connection. |
| `{:prompt_sent, id}` | the moment `session/prompt` is on the wire, first turn and every `prompt/3` | Persist on the turn. After a restart, a peer started with `attach: id` joins the turn already in flight and closes it on the response to that id. |
| `{:handshake_ms, ms, method}` | `initialize` answered | A metric, labelled with the session call about to be made (`"session/new"`, `"session/resume"`, `"session/load"`), because those pay different prices. |
| `{:model_rejected, requested, detail}` | the agent refused the configured model | Tell the user; the turn goes on with the runtime's default. |
| `{:permission_ask, request_id, tool, options}` | the policy said `ask` | Show `options` to a human, arm a timeout (`Permissions.ask_timeout_ms/1`), answer with `Peer.answer_permission/3` or `Peer.deny_permission/2`. Persist `%{"request_id" => …, "tool" => …, "options" => […]}` as `pending_permission:` for a reattached peer, so a request raised before a restart is still answerable after one. The same request also arrives as a `{:lines, "acp", …}` so it renders inline as a `:permission_request` block. |
| `{:permission_denied, tool, verdict}` | the policy said `auto_deny` (or a value that is not a verdict) | Audit it. Allows are deliberately not reported. |
| `{:cycle_end, kind}` | a `usage_update` whose origin is in the adapter's autonomous set (a background task's follow-up) | Close whatever turn the owner opened for the out-of-turn lines. |
| `{:done, stop_reason, usage}` | the `session/prompt` response | The turn is over and the peer is `:idle`; `usage` is `Usage.t()` or `nil`. The next `prompt/3` reuses the connection. |
| `{:failed, reason}` | a write failed, a request errored, or the session could not be set up | Terminal for the peer's writing. Close the turn, then `Peer.close/1`. Reasons: `{:acp_write_failed, reason}`, `{:acp_error, tag, error}`, `{:acp_no_session_id, result}`, `:acp_resume_without_session_id`, `:acp_agent_cannot_resume`, and two the owner can act on, `{:oauth_org_not_allowed, detail}` and `{:model_unavailable, model, detail}`. |

Ten payloads, all from `Peer`. The two failure reasons at the end are worth
matching on: one is the runtime's OAuth token belonging to an organisation
that disabled subscription access, the other a provider refusing the model
itself, and both reach the tenant as a sentence rather than an inspected
tuple.

## Permissions

A policy is a map of key to verdict plus a `"default"`:

```elixir
%{"default" => "auto_allow", "execute" => "ask", "rm -rf /" => "auto_deny"}
```

A request is matched most-specific-first: the tool card's title, then ACP's
coarse `kind` (`read`, `edit`, `delete`, `move`, `search`, `execute`, `think`,
`fetch`, `switch_mode`, `other`), then `"default"`. Reach for `kind` unless you
know the runtime's titles: claude-agent-acp titles a tool call with the command
itself, so a title key matches exactly one invocation.

| verdict | what answers |
|---|---|
| `auto_allow` | `allow_always`, else `allow_once`, else the first option offered (parity with the pre-policy constant) |
| `auto_deny` | a `reject_*` option when the agent offered one, `cancelled` when it did not; never an allow, never an invented id |
| `ask` | a human, through the owner, within a timeout — then deny |

`Permissions.effective(agent_policy, launch_policy)` takes the stricter verdict
for every key, so a launch may narrow a policy and never widen it, and
`Permissions.check_narrows/2` refuses a widening launch at the door with the
key it would loosen. The ask timeout is the host's configuration, passed in:
`Permissions.ask_timeout_ms(configured_seconds)` owns the default (five
minutes) and the parsing, and a value it cannot read is the default, never
"never deny". The library reads no configuration.

## Blocks

`Blocks.from_line/1` turns one stored protocol line into zero or more block
maps; `Blocks.from_update/1` takes the notification's params. Chunks are
emitted one block per chunk and left for the renderer to concatenate.

| Block | Shape | From |
|---|---|---|
| text | `%{kind: :text, body: String.t()}` | `agent_message_chunk` |
| thinking | `%{kind: :thinking, body: String.t()}` | `agent_thought_chunk` |
| tool use | `%{kind: :tool_use, id: String.t(), name: String.t(), summary: String.t(), body: String.t()}` | `tool_call`; `name` is the title, else the kind, never empty; `summary` is the first location's path, else a preview of `rawInput` |
| tool result | `%{kind: :tool_result, tool_id: String.t(), body: String.t(), error?: boolean()}` | `tool_call_update` with a terminal status (`completed`, `failed`, `cancelled`); in-flight updates produce nothing |
| permission request | `%{kind: :permission_request, request_id: String.t(), name: String.t(), summary: String.t(), options: [map()]}` | `session/request_permission`; `options` is exactly what the agent offered, in its order |
| raw | `%{kind: :raw, body: String.t(), summary: "raw"}` | a line that is not JSON |

`user_message_chunk`, `plan`, `available_commands_update`, `usage_update` and
any variant a future adapter invents produce nothing: for a well-specified
protocol, rendering every new notification kind as noise would be the bug.

## Testing a host

`Managoat.ACP.Testing.ScriptedAgent` is the other end of the seam:

```elixir
{:ok, agent} = ScriptedAgent.start_link(updates: [chunk("hello")], permission: request)
{:ok, peer} = Peer.start(owner: self(), writer: ScriptedAgent.writer(agent), ref: make_ref(), prompt: "hi", mode: :run, session_id: nil, permission_policy: %{"default" => "ask"})
:ok = ScriptedAgent.connect(agent, peer)

assert_receive {:acp, _, {:permission_ask, request_id, _tool, _options}}
:ok = Peer.answer_permission(peer, request_id, "yes")
assert_receive {:acp, _, {:done, "end_turn", nil}}
```

Every frame the peer writes is also reported to the test process as
`{:scripted_agent, :wrote, decoded}`. The library's own peer tests script the
agent by hand, one frame at a time, because they are about the frames; the
scripted agent is for a host's tests, which are about turns.

## How this relates to acpex and agent_client_protocol

Two ACP packages are on hex. This section is the evaluation Fountain's #1339
asked for, written after reading both source trees on 2026-09-02, and it ends
with a recommendation. The protocol version to compare against is
`protocolVersion: 1`, which is what [agentclientprotocol.com](https://agentclientprotocol.com/protocol/initialization)
says a client sends today; the spec bumps the number only for breaking
changes, and the session methods beyond the baseline (`session/resume`,
`session/fork`, `session/set_model`, `session/set_config_option`) are
unstable extensions that the adapters in the wild already implement.

### Side by side

| | `managoat_acp` (this package) | [`acpex`](https://github.com/lostbean/acpex) 0.1.1 | [`agent_client_protocol`](https://github.com/f1729/agent-client-protocol-elixir) 0.1.0 |
|---|---|---|---|
| **What it is** | Client side only. A session process that outlives the turn, plus policy, blocks, usage and a tracer. | Both sides: `ACPex.Client` and `ACPex.Agent` behaviours over one `ACPex.Protocol.Connection`, with a `Session` process per session id under a supervisor. | Both sides: `ACP.Client` and `ACP.Agent` behaviours, `ACP.Connection` over IO devices, `ACP.ClientSideConnection` with typed request functions. A port of the Rust `agent-client-protocol` crate. |
| **Transport it assumes** | None. A writer function for bytes out, `Peer.stdout/2` for bytes in. Fountain's writer wraps a sandbox command; a stdio host wraps a `Port`; tests wrap a function. | An Erlang `Port` it opens itself (`ACPex.Transport.Ndjson`, `{:line, 1 MiB}` packet mode; a line over that is split and only the `:eol` part is parsed). `transport_pid:` accepts a custom process that speaks its `{:send_message, map}` / `{:message, map}` messages. Stdio to a child process, in practice. | An IO device: a `spawn_link`ed loop calls `IO.read(device, :line)` and posts each line to the connection; output is `IO.write`. Pull-shaped: to feed it bytes from a message you have to build an IO device. |
| **JSON-RPC layer** | `Protocol` (150 lines, pure): `feed/2` buffers the partial tail across chunks, `classify/1`, encoders for request, notification, response, error. Correlation lives in the peer as a `pending` map of id to a tag naming the call (`:initialize`, `:prompt`, …), so a response is handled by what it answers. Cancellation is `session/cancel` as a notification; the turn ends on the prompt's own `cancelled` response, as the spec says. A response to an unknown id is a warning, or expected when attached mid-turn. | `Connection.send_request/4` is a blocking `GenServer.call` with a 5 s default timeout and a pending map of id to caller; the caller must be a different process. No cancellation API (`session/cancel` is a schema type; the client would send it as a notification by hand). Incoming methods are dispatched by `String.to_atom("handle_" <> method)` on wire input. **Could ours be replaced by it?** No: the connection owns the transport process and the request API blocks, while the peer is a state machine that needs non-blocking sends and push-shaped input. | `ACP.Connection.request/4` is a blocking `GenServer.call`, 30 s default; ids from 0; pending map. Incoming requests are handled in an unlinked `Task.start`, so a `request_permission` handler may block on a human but nothing bounds it and there is no id to answer later from outside. `ACP.RPC.JsonRpcMessage.encode!/1` and `decode/1` are pure and could replace four of `Protocol`'s encoders and `classify_line/1` (about 60 lines); `feed/2` has no equivalent because the package never buffers, and `decode/1` refuses a line without `"jsonrpc":"2.0"`, which claude-agent-acp's stray stdout lines lack anyway. **Could ours be replaced by it?** The encoding half, at the cost of a 6,800-line dependency for 60 lines. |
| **Schema layer** | None. Maps with the wire's camelCase keys; the peer reads the dozen fields it needs. | All 27 protocol types as **Ecto embedded schemas** with `:source` mappings for camelCase, encoded and decoded through `ACPex.Schema.Codec` (`Ecto.embedded_dump/2`). Depends on `ecto ~> 3.11`. Covers `initialize`, `authenticate`, `session/new`, `session/prompt`, `session/cancel`, `session/update` and its variants, content blocks, `fs/*`, `terminal/*`. **No** `session/request_permission`, `session/load`, `session/resume`, `session/set_model`, `session/set_config_option`, or usage. **Adopting it without Ecto:** not possible; Ecto is the schema mechanism. | 92 modules of plain structs with `to_json/1` and `from_json/1`, depending on `jason` only. Covers everything acpex does plus `RequestPermissionRequest/Response`, `PermissionOption`, `LoadSession`, and the unstable set (`ResumeSession`, `ForkSession`, `SetSessionModel`, `SetSessionConfigOption`, `SessionInfoUpdate`, `ConfigOptionUpdate`). **Adopting it without Ecto:** possible in principle. In practice `ACP.SessionUpdate.from_json/1` has no clause for a variant it does not know, so a `usage_update` (which claude-agent-acp sends on every turn, and which this package's `:cycle_end` depends on) raises `FunctionClauseError` inside `ACP.SessionNotification.from_json/1`, which the connection pattern-matches with `{:ok, notif} =` and crashes on. |
| **What it has that we lack** | — | A typed schema for the 27 stable types; an agent-side behaviour; a supervised transport for a child process; `fs/*` and `terminal/*` client callbacks; guides and livebooks. | A typed schema including the unstable session types and permission types; an agent-side behaviour; typed client request functions (`initialize/2`, `new_session/2`, `load_session/2`, `prompt/2`, `cancel/2`); `ext_method` / `ext_notification` for `_`-prefixed extensions; a stream broadcaster for observing frames. |
| **What we have that it lacks** | — | A session that outlives the turn and reattaches mid-turn with replay discard and a dropped partial first line; `session/resume` with `session/load` as the fallback and a quiet-period window for agents that answer `load` before replaying; authentication on demand, api-key methods only; model pinning through two adapter shapes; **any answer at all to `session/request_permission`** (routed by `sessionId` to the session process, which answers `-32601` because `ACPex.Client` has no callback for it, so every tool call under a real adapter is refused); a permission policy with most-specific-first matching, narrow-never-widen merging and a timeout; minted request ids that survive an adapter numbering its requests from 0 per turn; block normalisation; usage; the tracer; a transport that is not a child process. | The same session layer; the policy; blocks; usage; the tracer; a request id the host can answer later, from another process, after a restart; a transport that is not an IO device. |
| **Licence** | Apache-2.0 | Apache-2.0 | MIT |
| **Last release** | unreleased (umbrella app) | 0.1.1 on 2026-06-17 (0.1.0 on 2025-10-09) | 0.1.0 on 2026-01-29, the only release |
| **Activity** | this repository's | 30 commits by one author (two names, one person): 28 in the week of 2025-10-05, a toolchain update and the 0.1.1 release in June 2026. Requires **Elixir ~> 1.20**; Fountain pins 1.19.2. | 3 commits by one author, all on 2026-01-29, nothing since. Requires Elixir ~> 1.19. |
| **Open issues, bus factor** | — | 0 open issues, 1 open PR (a dependency bump, 2026-05-25). 11 stars, 3 forks. Bus factor 1. | 0 open issues, 0 PRs. 4 stars, 1 fork. Bus factor 1, and dormant. |
| **Protocol version** | `protocolVersion: 1` sent; unstable methods used where the agent advertises them. | `protocol_version: 1` in `InitializeRequest`; no unstable methods. | `ACP.ProtocolVersion.latest/0` is 1; README says it targets schema 0.10.6; unstable types included and flagged. |

Hex download counts are near-identical for both (17.5k and 17.1k, all-time)
and say nothing about use; that shape is mirror traffic.

### Recommendation

**Publish `managoat_acp` as it is, the whole stack, and do not build it on
either package.**

- `acpex` cannot be the JSON-RPC layer (its connection owns the transport and
  blocks the caller) and cannot be the schema layer without taking Ecto into
  a library whose point is to be Repo-free. It also requires Elixir 1.20,
  which this umbrella does not run, and as a client it cannot answer a
  permission request or resume a session, which are the two things every
  adapter we run needs. There is nothing here to contribute the session
  layer *to*: it would be a rewrite of their connection, not an addition.
- `agent_client_protocol` is the better-shaped package — jason only, the
  unstable types, a real `request_permission` callback — but it is one day
  of commits by one person seven months ago, its `SessionUpdate` decoder
  crashes the connection on the first `usage_update`, and its transport is
  an IO device. Depending on it for 60 lines of encoding would trade a
  seam this repository controls for one nobody maintains. Contributing our
  session layer upstream would mean asking a dormant project to take a
  design (push-shaped transport, owner messages, a request id answerable from
  outside) that inverts its own, which is not a contribution they would
  take, and not one we could wait on.

What is worth revisiting: **the typed schema.** If `agent_client_protocol`
shows a second release, its structs are the one thing worth adopting, as an
optional decode step at the edges (`Blocks`, `Usage`, the permission request)
rather than in the peer, and the unknown-variant crash would be the first
patch to send. Until then, maps with the wire's own names are the cheaper
contract, and every field the peer reads is one the adapters were measured
sending.

Graduation to a `managoat/acp` repository is #1345's business and is not
gated by this evaluation.

## Origins

Extracted from [Fountain](https://github.com/BinaryBourbon/fountain) under
[ADR 0037](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0037-component-libraries.md)
(issue #1339), where the peer was built as gate 2 of ADR 0014 and the policy
as gate 3. The issue numbers in the code are that repository's; each marks an
agent behaviour that was measured live and that the code is shaped around.
Apache-2.0.
