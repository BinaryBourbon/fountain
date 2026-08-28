# OpenAI-compatible API

Fountain answers `POST /v1/chat/completions`, the request shape that every AI
gateway and every chat client with a base-URL field already speaks. The
`model` is a Fountain agent. Point LiteLLM, Portkey, Kong AI Gateway,
Cloudflare AI Gateway, Open WebUI, LibreChat, the `openai` SDK in any
language, or `curl` at `https://your-fountain/v1` with an API key. The client
sees a model that answers in text. Behind it, an agent runs for as long as it
needs to in a sandbox of its own.

```
  Open WebUI / LiteLLM / openai SDK  ──HTTPS──▶  Fountain                  ──▶  sandbox: the Fountain agent
    base URL = https://your-fountain/v1          POST /v1/chat/completions     (its environment, vault, runtime)
    model    = pr-reviewer                       GET  /v1/models
    ◀── chat.completion, or chat.completion.chunk as SSE
```

There is no plugin and no code on the client. The base URL, a key, and one
header are the whole integration.

## Summary

| | |
|---|---|
| Direction | Inbound. The client or gateway drives Fountain. |
| Talks over | OpenAI chat completions, at `POST /v1/chat/completions` and `GET /v1/models`. |
| Configured on | The client or the gateway. |
| Plugin | None. A URL is the whole integration. |
| Credential | A Fountain API key, as the bearer token. |
| Scope | One thread key is one conversation is one sandbox. |
| Status | Alpha. Behind the `openai_compat` flag, off by default on the hosted platform. Read [Feature status](../reference/feature-status.md). |

!!! note "Alpha"
    On the hosted platform the flag is off by default.
    [Ask us](../api.md#support) to turn it on for your account. Fountain
    answers `404` with code `openai_compat_not_enabled` while it is off. The
    thread-key rule, `reasoning_content` and the error codes can change
    between releases.

## Set it up

Make an API key.

```bash
fountain keys create open-webui
```

Then give the client three things.

| Field | Value |
|---|---|
| Base URL | `https://your-fountain/v1` |
| API key | `ftn_...` |
| Model | The agent's name, as `GET /v1/models` lists it. |

Most clients fetch `GET /v1/models` on save and fill their model picker with
your agents. If a client asks for a model name by hand, use the agent's name.
The agent's id works too.

From the `openai` Python SDK:

```python
from openai import OpenAI

client = OpenAI(base_url="https://your-fountain/v1", api_key="ftn_...")

reply = client.chat.completions.create(
    model="pr-reviewer",
    messages=[{"role": "user", "content": "Review the open PRs on fountain."}],
    extra_headers={"X-Fountain-Thread": "prs-2026-08-25"},
    stream=True,
)
for chunk in reply:
    print(chunk.choices[0].delta.content or "", end="")
```

From `curl`:

```bash
curl https://your-fountain/v1/chat/completions \
  -H "Authorization: Bearer ftn_..." \
  -H "X-Fountain-Thread: prs-2026-08-25" \
  -H "Content-Type: application/json" \
  -d '{"model": "pr-reviewer", "stream": true,
       "messages": [{"role": "user", "content": "Review the open PRs on fountain."}]}'
```

A complete terminal chat on the `openai` package, with the model picker and
the thread header in place, is in the repository at
[`examples/openai-chat`](https://github.com/BinaryBourbon/fountain/tree/main/examples/openai-chat).
For LangChain and Deep Agents, where a Fountain agent is a subagent, read
[LangChain and Deep Agents](langchain.md).

## One thread is one conversation is one sandbox

Understand this part. Chat completions are stateless. The client sends the
whole history on every call and expects the server to keep nothing. A Fountain
conversation is the opposite. The sandbox holds the context, which is the
agent's files, its shell history, and what it worked out last turn. Replay
the transcript into it on each call, and you feed the agent its own words
back.

So Fountain **maps** each chat to a conversation, and does not replay it. It
sends only the newest `user` message of each request as the prompt. The first
request on a thread opens a conversation. Each later request prompts the
conversation already bound to it.

The request has no field for a thread. Fountain reads the key from one of
two places, in this order.

1. The `X-Fountain-Thread` header. Set it to a stable id for the chat, such as
   the chat's own id in your client. Any gateway that forwards headers
   forwards this one.
2. The `user` field of the request, when the header is absent. Every SDK
   exposes it, and Open WebUI and LibreChat set it to the person's id. A
   client that cannot set headers gets one sandbox for each person and agent,
   which that person talks to for as long as they like. That is the same
   model as the [team page](../concepts/teammates.md).

Fountain refuses a request with neither, with a 400 that names the header. It
does not fall back to one conversation for each message. That would spawn a
sandbox for each line of a chat, and it is the failure mode this endpoint
exists to avoid.

The key binds as channel `openai:<key>`, scoped to your account. Two accounts
whose clients mint the same key share nothing. The conversations appear in
Fountain like any others, and the API filters on the channel.

```bash
curl -H "Authorization: Bearer ftn_..." \
  "https://your-fountain/api/conversations?channel_id=openai:prs-2026-08-25"
```

### The system prompt

A client sends its system prompt on every call. Fountain delivers `system`
and `developer` messages **once**, with the first prompt of a new
conversation. After that the agent has it, and to repeat it each turn is
noise in the transcript and tokens on the bill.

That choice has a cost. Edit the system prompt in your client and it reaches
a new thread. It does not reach a sandbox that already booted with the old
one. Start a new thread to apply a system prompt you rewrote.

An agent's own system prompt still applies. It is the better place for
whatever must hold on each surface.

### Images

An `image_url` part on the newest user message becomes a prompt image, the
same as `images` on the real API. The URL must be a `data:` URL. Fountain does
not fetch a remote image on the client's behalf. Every chat client that
attaches a file inlines it as a data URL.

## What comes back

| Fountain | Chat completions |
|---|---|
| `text` blocks | `content` |
| `thinking` blocks | `reasoning_content` |
| `tool_use` and `tool_result` | `reasoning_content`, one line for each call, such as `→ Bash` and `← ok`. |
| The `provision` and `setup` stages | `reasoning_content`, such as `provision: started`. |
| A call to one of your `tools` | `tool_calls`, then `finish_reason: "tool_calls"`. Read [Your tools](#your-tools). |
| `turn`/`done` | `finish_reason: "stop"` |
| `turn`/`failed` | An `error` object that carries the reason. |

With `stream: true`, the reply is SSE. Each event is a `chat.completion.chunk`
and the stream ends with `data: [DONE]`, as OpenAI sends it. With
`stream: false`, the request blocks until the turn ends and answers with one
`chat.completion`. A turn can take minutes, so set the client's timeout with
that in mind, or stream.

`reasoning_content` is the field that Open WebUI, LibreChat and LiteLLM show
as the model's thoughts. A client that does not know the field ignores it.
Either way the bytes keep the client's stall watchdog fed while a fresh
sandbox provisions, which takes longer than a minute on some providers.

Two fields carry no information here, on purpose.

- `usage` is always zeros. Fountain bills a turn in seconds, not tokens, and
  an invented token count is a number that a gateway would then add up.
- `finish_reason` is `stop`, or `tool_calls` when the agent waits on one of
  your tools. It is never `length`.

**The sandbox's own tools never come back as tool calls.** On this protocol
a tool call means *client, run this and send me the result*. A Fountain agent
ran its own tool, in its own sandbox, and the result is already in the text.
The client sees what the agent said, not what it did. The tools that *you*
define on the request are the exception, and the next section is about them.

The reply also carries a `fountain` object with the `conversation_id`, the
`turn_id` and the `thread`. Use them to reach the same conversation over the
[real API](../api.md#conversations).

## Your tools

Send `tools` on the request, in OpenAI's function shape, and the agent gets
them beside its own. The agent does not know that they are remote. When it
calls one, the completion ends with the call and `finish_reason:
"tool_calls"`, and the turn waits. Run the tool, then send the next request
on the same thread with a `role: "tool"` message for each call. The turn
continues, and the completion ends with `stop` or with the next call. Every
agent framework already runs this loop. So a Fountain agent can be the model
inside `create_agent`, the `openai` SDK's tool runner, or Open WebUI's tool
servers.

```
  1. POST /v1/chat/completions   tools: [lookup_order]      ──▶  the agent calls lookup_order
     ◀── finish_reason: "tool_calls", tool_calls: [{id: "call_1", function: {name, arguments}}]
  2. POST /v1/chat/completions   messages: [..., {role: "tool", tool_call_id: "call_1", content: "..."}]
     ◀── the rest of the turn, finish_reason: "stop"
```

From the `openai` Python SDK, the two requests are what
`client.chat.completions.create` returns and what you send back:

```python
tools = [{"type": "function", "function": {
    "name": "lookup_order",
    "description": "Find an order by id",
    "parameters": {"type": "object", "properties": {"id": {"type": "string"}}},
}}]
headers = {"X-Fountain-Thread": "orders-1"}
messages = [{"role": "user", "content": "Where is order A-17?"}]

reply = client.chat.completions.create(model="support", messages=messages,
                                       tools=tools, extra_headers=headers)
call = reply.choices[0].message.tool_calls[0]
messages += [reply.choices[0].message,
             {"role": "tool", "tool_call_id": call.id, "content": lookup_order(**json.loads(call.function.arguments))}]
reply = client.chat.completions.create(model="support", messages=messages,
                                       tools=tools, extra_headers=headers)
print(reply.choices[0].message.content)
```

Some rules.

- Fountain stores the tool names, descriptions and schemas on the
  conversation. Send the same `tools` on each request. A changed list
  replaces the old one at the next turn.
- A call has a deadline, the same one as a permission prompt (five minutes by
  default). If you do not answer in time, the agent gets an error result that
  says so, and the turn continues without it.
- Fountain refuses a `user` message while a call waits, with `409` and code
  `tool_calls_pending`. Answer the call first.
- Fountain refuses a `role: "tool"` message when nothing waits, with `400`
  and code `no_pending_tool_calls`. The turn may have ended, or the call may
  have expired.
- `tool_choice: "none"` sends no tools for that request. Fountain refuses
  `required` and a named tool with `400`, because it cannot force an agent's
  next action.
- The agent can make more than one call at once. Fountain returns them one
  at a time. Answer each one, and the next comes back at once.
- `reasoning_content` carries a line for each call, such as
  `→ lookup_order (waiting for the caller)`, so a client that ignores
  `tool_calls` can see why the reply stopped.

The agent reaches your tools through one more Fountain-served MCP server in
its sandbox. A parked call blocks the agent's tool call for up to a minute,
then returns `pending` with a `call_id`, and the agent calls
`wait_for_caller_result` until you answer. Fountain reserves that name.

## Errors

Errors that arrive before the reply use OpenAI's envelope, with the status
that a client acts on.

| Status | `code` | When |
|---|---|---|
| 400 | | No thread key, no user message, or a remote `image_url`. |
| 401 | | No key, or a bad one. |
| 402 | `insufficient_credits` | No credit on the account. |
| 404 | `model_not_found` | No agent has that name or id in your account. |
| 409 | `thread_busy` | The thread runs a turn now. `Retry-After` says when to send again. |
| 409 | `tool_calls_pending` | The thread waits on your tool results. Answer them with `role: "tool"` messages. |
| 400 | `no_pending_tool_calls` | The newest messages are tool results, but nothing waits for them. |
| 429 | `sandbox_quota_exceeded` | Your concurrency cap. Terminate a conversation, or wait for one to idle out. |

Fountain refuses a second request on a thread that is mid-turn, and does not
queue it. Chat clients retry, and `Retry-After` tells them when.

A turn that fails after the reply started is an `error` event on the stream,
followed by `[DONE]`. With `stream: false` it is a 500 with `code`
`turn_failed`.

## Model credentials

The agent needs a model credential here, as it does on each other surface. Add
one at `/account/inference-credentials`. Without one the sandbox spawns, the
session initialises, and the turn fails with `Authentication required`, which
reaches the client as an error that names it. Fountain has no platform-level
model key, on purpose
([ADR 0008](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0008-byo-inference-credentials.md)).

## What it does not do

- Structured outputs, logprobs, `n > 1`, `tool_choice: "required"`, or
  other features that assume the thing behind the URL is a model.
- The Anthropic Messages shape. One dialect, and the OpenAI one is what
  gateways and clients speak.
- A model-provider abstraction for the sandbox side. To point the *runtime*
  at a gateway is an environment variable on the agent's environment.

The decision to carry a second public dialect on the server, and what it
constrains, is
[ADR 0035](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0035-openai-compatible-endpoint.md).
