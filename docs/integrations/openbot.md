# OpenBot (AG-UI)

[OpenBot](https://copilotkit.ai/openbot) is CopilotKit's self-hosted agent
platform: channels, a coworker roster, an audit trail, and a browser computer
per bot. A "Bot" there is not a framework or an SDK. It is **any HTTP endpoint
speaking [AG-UI](https://github.com/ag-ui-protocol/ag-ui)**, the open protocol
for agent-to-user interaction.

Fountain speaks it. `POST /api/agui/:agent_id` takes AG-UI's `RunAgentInput`
and answers with its SSE event stream, so a Fountain agent arrives in OpenBot
as a coworker with a channel of its own, with no plugin, no sidecar and no code on the
OpenBot host.

```
  OpenBot (channels, roster, audit)  ──HTTPS──▶  Fountain            ──▶  sandbox: the Fountain agent
    one channel = one thread                     POST /api/agui/:id       (its environment, vault, runtime)
    ◀── SSE: RUN_STARTED, TEXT_MESSAGE_*, THINKING_*, RUN_FINISHED
```

The endpoint is not OpenBot-specific. Any AG-UI host, whether a hand-written
client or another product built on the protocol, registers a Fountain agent the same
way. OpenBot is the host it was built and verified against, nothing more.

## Set it up

You need two things from Fountain: the agent's id, and an API key.

```bash
fountain agents list                 # the id
fountain auth api-keys create openbot
```

In OpenBot, open `/agents`, create a coworker, and fill in:

| Field | Value |
|---|---|
| Name / Title | Whatever the coworker should be called |
| Role description | The standing role, as below |
| AG-UI endpoint | `https://your-fountain/api/agui/<agent_id>` |
| Authorization header | `Authorization` / `Bearer ftn_...` |

OpenBot's **Test connection** button runs a real AG-UI run against the endpoint
before saving it, so a typo, a dead host or a wrong key is named at the form
rather than in a channel. It provisions a sandbox to answer, and that sandbox
counts against your concurrency quota until it idles out.

Running both on one laptop, OpenBot refuses a loopback endpoint unless its
`.env` has `AGENT_COMPUTER_ALLOW_PRIVATE_HOSTS=true`, the same target check
that governs browser navigation. It ships set for local development.

Declaring the coworker in a tenant package works too:

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

This is the part worth understanding, because the two products disagree about
where an agent's memory lives and the endpoint resolves it in Fountain's
favour.

An AG-UI host holds the transcript. It replays the entire message list on every
run and expects the endpoint to be stateless. A Fountain conversation is the
opposite. The sandbox holds the context, meaning the agent's files, its shell
history and what it worked out last turn, and replaying the transcript into it each turn
would feed the agent its own words back.

So the thread is **mapped**, not replayed. OpenBot mints a stable thread id per
channel; that becomes the channel binding `agui:<threadId>`, and only the
newest user message of each run is sent as a prompt. The first run on a thread
opens a conversation, and every later run prompts the one already bound.

The consequences are all the ones you would want.

- Starting a new channel in OpenBot starts a new sandbox.
- Two channels with the same coworker are two sandboxes that know nothing of
  each other.
- A channel picks up where it left off, including after the sandbox has idled
  out and been suspended, and the next message wakes it.
- The binding is per tenant, so two accounts whose hosts happen to mint the
  same thread id never share anything.

The conversations show up in Fountain like any others, with `channel_id`
`agui:<threadId>`:

```bash
fountain conversations list --channel "agui:<threadId>"
```

### The standing role

OpenBot sends a coworker's title and role description as an AG-UI system
message on every run. Fountain delivers it **once**, with the first prompt of a
new conversation, because after that the agent has it and repeating it every
turn is noise in the transcript and tokens on the bill.

The cost of that choice: editing a role in OpenBot reaches new channels, not
the sandbox that already booted with the old one. Start a new channel to apply
a rewritten role.

An agent's own system prompt still applies, and is the better place for
anything that should hold for every surface.

## What comes back

| Fountain | AG-UI |
|---|---|
| `text` blocks | `TEXT_MESSAGE_START` / `CONTENT` / `END` |
| `thinking` blocks | `THINKING_*` |
| `tool_use` / `tool_result` | `THINKING_*`, one line per call (`→ Terminal`, `← ok`) |
| `provision`, `setup`, … stages | `THINKING_*`, such as `provision: started` |
| `turn`/`done` | `RUN_FINISHED` |
| `turn`/`failed` | `RUN_ERROR`, carrying the reason |

`?activity=off` on the endpoint drops everything but the reply text.

**No AG-UI tool call is ever emitted**, and that is deliberate. On this
protocol a tool call means *host, run this and send me the result*: the run
ends, the host executes it, and a second run carries the result back. A
Fountain agent ran its own tool, inside its own sandbox, and already has the
result. Reporting it as a call would ask the host to execute something twice
and leave the run waiting for a result that is never coming. Tool activity is
reported as reasoning instead, which no host tries to execute.

The other side of that coin: **OpenBot's governance does not reach inside a
Fountain sandbox.** Its boundary is the gateway that every browser, file and
MCP tool call passes through, and a Fountain agent's `bash` never goes near it,
so `/admin/audit` and `/admin/boundaries` have nothing to say about what the
agent did. A Fountain agent is governed by Fountain, with its own audit trail, its
environment, its vault, its sandbox provider. Register one as a coworker in the
knowledge that you are trusting Fountain's boundary, not OpenBot's.

Bridging OpenBot's tools *into* the sandbox, so its computer, components and
MCP grants are things a Fountain agent can call and OpenBot can refuse, is the
other half of this integration and is not built.

## Timing, and a watchdog to know about

OpenBot ends a turn whose stream has been silent for `AGENT_STALL_TIMEOUT_MS`
(a minute by default). It measures silence, not duration: a turn may run for an
hour as long as events keep arriving.

Provisioning a fresh sandbox takes longer than a minute on some providers, and
a first run would otherwise be killed mid-provision. Two things keep it alive:
the lifecycle stages stream as thinking events, and the endpoint writes an SSE
heartbeat comment every 15 seconds. Both are bytes on the wire, which is what
the watchdog counts.

Whether a host *renders* thinking events is its own business. OpenBot's
channel view (CopilotKit 1.67.1) does not show them, so a first run looks quiet
even though the connection is healthy. Subsequent runs on a warm sandbox answer
in a couple of seconds.

If a Fountain error arrives before the stream opens, such as an unknown agent,
no subscription or the sandbox quota, it is an ordinary JSON response with a
status, and OpenBot shows it in the channel. Once the stream is open, failure
arrives as `RUN_ERROR`.

## Model credentials

The agent needs a model credential, as it does on every other surface: add one
at `/account/inference-credentials` (an Anthropic API key or Claude Code OAuth
token, an OpenAI key, a Gemini key). Without it the sandbox spawns, the ACP
session initialises, and the turn fails with `Authentication required`, which is a
`RUN_ERROR` in the channel that names it.

Fountain has no platform-level model key on purpose
([ADR 0008](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0008-byo-inference-credentials.md)).

## What it does not do yet

- **No tool bridge**, as above.
- **One key, one tenant.** The bot's stored key is a Fountain API key, so every
  OpenBot user in a deployment reaches Fountain as the account that owns it.
  OpenBot's own `actor.id` does not travel.
- **No approvals.** OpenBot can hand control to a person mid-run; a Fountain
  agent asking permission for a tool call has nowhere to ask
  ([#643](https://github.com/BinaryBourbon/fountain/issues/643)).
- **Attachments** on an OpenBot message are not forwarded; the prompt is text.

## Verify it

Against a running instance, with `curl`:

```bash
curl -N -X POST "https://your-fountain/api/agui/<agent_id>" \
  -H "Authorization: Bearer ftn_..." \
  -H "content-type: application/json" \
  -H "accept: text/event-stream" \
  -d '{"threadId":"probe-1","runId":"run-1",
       "messages":[{"role":"user","content":"Say hello in five words."}],
       "tools":[],"context":[],"state":{},"forwardedProps":{}}'
```

A healthy run is `RUN_STARTED`, some `TEXT_MESSAGE_*`, then `RUN_FINISHED`.
Each SSE message is `data: {"type": ...}`, so the type is inside the JSON, which
is what the reference AG-UI encoder writes and every client parses.
