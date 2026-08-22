# OpenBot (AG-UI)

[OpenBot](https://copilotkit.ai/openbot) is CopilotKit's self-hosted agent
platform. It has channels, a coworker roster, an audit trail, and a browser
computer for each bot. A "Bot" there is not a framework and not an SDK. It is
**any HTTP endpoint that speaks
[AG-UI](https://github.com/ag-ui-protocol/ag-ui)**, the open protocol for
interaction between an agent and a user.

Fountain speaks it. `POST /api/agui/:agent_id` takes AG-UI's `RunAgentInput`
and answers with its SSE event stream. A Fountain agent therefore arrives in
OpenBot as a coworker with a channel of its own. There is no plugin, no
sidecar, and no code on the OpenBot host.

```
  OpenBot (channels, roster, audit)  ──HTTPS──▶  Fountain            ──▶  sandbox: the Fountain agent
    one channel = one thread                     POST /api/agui/:id       (its environment, vault, runtime)
    ◀── SSE: RUN_STARTED, TEXT_MESSAGE_*, THINKING_*, RUN_FINISHED
```

The endpoint is not specific to OpenBot. Any AG-UI host registers a Fountain
agent the same way, whether it is a hand-written client or another product
built on the protocol. OpenBot is the host we built it against and verified it
against, and nothing more.

## At a glance

| | |
|---|---|
| Direction | Inbound. OpenBot drives Fountain. |
| Talks over | [AG-UI](https://github.com/ag-ui-protocol/ag-ui), at `POST /api/agui/:agent_id`. |
| Configured on | The OpenBot host. |
| Plugin | None. A URL is the whole integration. |
| Credential | An API key that the coworker holds. |
| Scope | One channel is one conversation is one sandbox. |

## Set it up

You need two things from Fountain. The agent's id, and an API key.

```bash
fountain agents list                 # the id
fountain auth api-keys create openbot
```

In OpenBot, open `/agents`, create a coworker, then complete four fields.

| Field | Value |
|---|---|
| Name / Title | Whatever you want the coworker called. |
| Role description | The role it always has, as below. |
| AG-UI endpoint | `https://your-fountain/api/agui/<agent_id>` |
| Authorization header | `Authorization` / `Bearer ftn_...` |

OpenBot's **Test connection** button runs a real AG-UI run against the
endpoint before it saves. So the form tells you about a typo, a dead host or a
wrong key, and a channel does not. That test provisions a sandbox to answer,
and that sandbox counts against your concurrency quota until it idles out.

If you run both on one laptop, OpenBot refuses a loopback endpoint. Set
`AGENT_COMPUTER_ALLOW_PRIVATE_HOSTS=true` in its `.env`. It is the same target
check that governs browser navigation, and OpenBot ships it set for local
development.

You can declare the coworker in a tenant package instead.

```yaml
agents:
  - id: ada
    name: Ada
    title: Fountain Agent
    role_description: Runs in its own sandbox.
    type: remote-ag-ui
    endpoint: https://your-fountain/api/agui/<agent_id>
```

## One channel is one conversation is one sandbox

Understand this part. The two products disagree about where an agent's memory
lives, and the endpoint resolves that in Fountain's favour.

An AG-UI host holds the transcript. It replays the whole message list on each
run, and expects the endpoint to be stateless.

A Fountain conversation is the opposite. The sandbox holds the context, which
is the agent's files, its shell history, and what it worked out last turn.
Replay the transcript into it each turn, and you feed the agent its own words
back.

So Fountain **maps** the thread, and does not replay it. OpenBot mints a
stable thread id for each channel. Fountain binds the channel as
`agui:<threadId>`, then sends the newest user message of each run as the
prompt. The first run on a thread opens a conversation. Each later run
prompts the conversation already bound to it.

The results are the ones you would want.

- A new channel in OpenBot starts a new sandbox.
- Two channels with the same coworker are two sandboxes, and neither knows
  about the other.
- A channel continues where it stopped. That holds after the sandbox idled out
  and suspended, and the next message wakes it.
- Fountain scopes that link to one tenant. Two accounts whose hosts happen to
  mint the same thread id share nothing.

The conversations appear in Fountain like any others, with a `channel_id` of
`agui:<threadId>`.

```bash
fountain conversations list --channel "agui:<threadId>"
```

### The standing role

OpenBot sends a coworker's title and role description as an AG-UI system
message on each run. Fountain delivers it **once**, with the first prompt of a
new conversation. After that the agent has it, and to repeat it each turn is
noise in the transcript and tokens on the bill.

That choice has a cost. Edit a role in OpenBot and it reaches a new channel.
It does not reach a sandbox that already booted with the old one. Start a new
channel to apply a role you rewrote.

An agent's own system prompt still applies. It is the better place for
whatever must hold on each surface.

## What comes back

| Fountain | AG-UI |
|---|---|
| `text` blocks | `TEXT_MESSAGE_START` / `CONTENT` / `END` |
| `thinking` blocks | `THINKING_*` |
| `tool_use` and `tool_result` | `THINKING_*`, one line for each call, such as `→ Terminal` and `← ok`. |
| The `provision`, `setup` and other stages | `THINKING_*`, such as `provision: started`. |
| `turn`/`done` | `RUN_FINISHED` |
| `turn`/`failed` | `RUN_ERROR`, which carries the reason. |

`?activity=off` on the endpoint drops everything except the reply text.

**Fountain never emits an AG-UI tool call**, and that is deliberate. On this
protocol a tool call means *host, run this and send me the result*. The run
ends, the host executes it, and a second run carries the result back.

A Fountain agent ran its own tool, in its own sandbox, and it already has the
result. To report that as a call would ask the host to execute something
twice. It would also leave the run to wait for a result that never comes. So Fountain
reports tool activity as reasoning, which no host tries to execute. <!-- vale disable-line STE.IngForms -->

Here is the other side of that coin. **OpenBot's governance does not reach
inside a Fountain sandbox.** Its boundary is the gateway that each browser,
file and MCP tool call passes through. A Fountain agent's `bash` never goes
near it, so `/admin/audit` and `/admin/boundaries` have nothing to say about
what the agent did.

Fountain governs a Fountain agent, with its own audit trail, its environment,
its vault and its sandbox provider. Register one as a coworker in the
knowledge that you trust Fountain's boundary, and not OpenBot's.

The other half of this integration would bridge OpenBot's tools *into* the
sandbox. Its computer, its components and its MCP grants would become things a
Fountain agent can call and OpenBot can refuse. Nobody built that.

## Timing, and a watchdog to know about

OpenBot ends a turn whose stream has been silent for `AGENT_STALL_TIMEOUT_MS`,
which is a minute by default. It measures silence, and not duration. A turn
can run for an hour, as long as more events arrive.

To provision a fresh sandbox takes longer than a minute on some providers, and
a first run would otherwise die mid-provision. Two things keep it alive. The
lifecycle stages stream as thinking events, and the endpoint writes an SSE <!-- vale disable-line STE.IngForms -->
heartbeat comment every 15 seconds. Both are bytes on the wire, which is what
the watchdog counts.

Whether a host *renders* a thinking event is its own business. OpenBot's <!-- vale disable-line STE.IngForms -->
channel view, on CopilotKit 1.67.1, does not show them. So a first run looks
quiet even while the connection is healthy. A later run on a warm sandbox
answers in a couple of seconds.

If a Fountain error arrives before the stream opens, it is an ordinary JSON
response with a status, and OpenBot shows it in the channel. An unknown agent,
no subscription and the sandbox quota are the three. Once the stream is open,
a failure arrives as `RUN_ERROR`.

## Model credentials

The agent needs a model credential here, as it does on each other surface. Add
one at `/account/inference-credentials`. That is an Anthropic API key or a
Claude Code OAuth token, an OpenAI key, or a Gemini key.

Without one the sandbox spawns, the ACP session initialises, and the turn
fails with `Authentication required`. That reaches the channel as a
`RUN_ERROR` that names it.

Fountain has no platform-level model key, on purpose
([ADR 0008](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0008-byo-inference-credentials.md)).

## What it does not do yet

- **No tool bridge**, as above.
- **One key, one tenant.** The bot's stored key is a Fountain API key, so each
  OpenBot user in a deployment reaches Fountain as the account that owns it.
  OpenBot's own `actor.id` does not travel.
- **No approvals.** OpenBot can hand control to a person mid-run. A Fountain
  agent that asks permission for a tool call has nowhere to ask
  ([#643](https://github.com/BinaryBourbon/fountain/issues/643)).
- **Attachments do not travel.** An attachment on an OpenBot message does not
  reach Fountain. The prompt is text.

## Verify it

Against a live instance, with `curl`:

```bash
curl -N -X POST "https://your-fountain/api/agui/<agent_id>" \
  -H "Authorization: Bearer ftn_..." \
  -H "content-type: application/json" \
  -H "accept: text/event-stream" \
  -d '{"threadId":"probe-1","runId":"run-1",
       "messages":[{"role":"user","content":"Say hello in five words."}],
       "tools":[],"context":[],"state":{},"forwardedProps":{}}'
```

A healthy run is `RUN_STARTED`, then some `TEXT_MESSAGE_*`, then
`RUN_FINISHED`. Each SSE message is `data: {"type": ...}`, so the type sits
inside the JSON. That is what the reference AG-UI encoder writes, and what
each client parses.

## Related

- [Agents as teammates](../concepts/teammates.md), the same
  one-channel-one-conversation idea inside Fountain.
- [API reference](../api.md).
- [Plug into Fountain](clients.md).
