# Behind an AI gateway

An AI gateway such as LiteLLM, Portkey, Kong AI Gateway or Cloudflare AI
Gateway routes a `model` name to an upstream. Fountain is one more upstream.
Its [OpenAI-compatible API](openai-compatible.md) is the wire, and every
agent on the account is a model. A person who already calls the gateway
calls `fountain/pr-reviewer` and talks to an agent. The agent runs for as
long as it needs to, in a sandbox of its own.

```
  any OpenAI client ──▶  gateway                  ──▶  Fountain /v1            ──▶  sandbox
    model = fountain/pr-reviewer   fountain/* → openai/*   model = pr-reviewer        the agent
    X-Fountain-Thread: chat-42     (header forwarded)      channel openai:chat-42
```

It rides on the OpenAI-compatible API, so it is alpha, behind the
`openai_compat` flag. There is no plugin. The gateway's own config is the
integration.

## At a glance

| | |
|---|---|
| Direction | Inbound. The gateway drives Fountain. |
| Talks over | OpenAI chat completions, at `POST /v1/chat/completions` and `GET /v1/models`. |
| Configured on | The gateway. |
| Plugin | None. An upstream entry in the gateway's config. |
| Credential | A Fountain API key, as the upstream's key. |
| Scope | One forwarded thread key is one conversation is one sandbox. |
| Status | Alpha, with the endpoint under it. Read [Feature status](../reference/feature-status.md). |

## Set it up

Make an API key for the gateway.

```bash
fountain keys create litellm
```

Then add Fountain as an upstream. Three settings matter, and each gateway
has its own name for them.

| Setting | Why |
|---|---|
| An OpenAI-compatible upstream at `https://your-fountain/v1`, with the key. | The `/v1` is part of the base URL. |
| Pass-through of the client's custom request headers. | `X-Fountain-Thread` must reach Fountain. The `user` field does not survive LiteLLM. Read [The thread](#the-thread). |
| An upstream timeout of many minutes. | A turn is an agent at work, not a model that answers. The first request on a thread also provisions a sandbox. |

For LiteLLM, that is this `config.yaml`.

```yaml
model_list:
  - model_name: "fountain/*"
    litellm_params:
      model: "openai/*"
      api_base: "os.environ/FOUNTAIN_URL"        # https://your-fountain/v1
      api_key: "os.environ/FOUNTAIN_API_KEY"
      timeout: 1800
      stream_timeout: 1800
      num_retries: 0

general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  forward_client_headers_to_llm_api: true      # X-Fountain-Thread reaches Fountain

litellm_settings:
  check_provider_endpoint: true                # /v1/models lists the agents
  drop_params: true                            # Fountain ignores temperature and friends
```

The wildcard maps `fountain/pr-reviewer` on the gateway to `pr-reviewer` on
Fountain. An agent you create tomorrow is routable with no restart.
`check_provider_endpoint` fills the gateway's `GET /v1/models` from
Fountain's list, so a chat client's picker shows the agents. A fixed alias
is the other shape, when a client must not know which agent answers.

```yaml
  - model_name: support
    litellm_params:
      model: openai/support-agent
      api_base: "os.environ/FOUNTAIN_URL"
      api_key: "os.environ/FOUNTAIN_API_KEY"
      timeout: 1800
```

The full example, with a `docker-compose.yml` and a smoke script, is
[`examples/litellm-gateway`](https://github.com/BinaryBourbon/fountain/tree/main/examples/litellm-gateway).

## The thread

Fountain keeps a chat in one sandbox by a thread key. It reads the
`X-Fountain-Thread` header, else the request's `user` field, and refuses a
request with neither. Read
[One thread is one conversation](openai-compatible.md#one-thread-is-one-conversation-is-one-sandbox).

A gateway sits between the client and that rule.

- **The header.** Most gateways strip custom headers unless told to forward
  them. On LiteLLM the setting is `forward_client_headers_to_llm_api: true`,
  which forwards every `x-` header. Without it, a client that sets the
  header gets a 400 from Fountain, which names the header, and the gateway
  relays that 400.
- **The `user` field.** Do not count on it through a gateway. LiteLLM
  follows OpenAI's parameter list, which no longer has `user`, and drops
  the field before it calls Fountain. It drops `metadata` too. We measured
  this on 2026-08-26 with the example's config and an echo server as the
  upstream.
- **The `safety_identifier` field.** This is the body field that survives
  LiteLLM. It is OpenAI's replacement for `user`, and Fountain reads it as
  the third key, after the header and `user`. A client with no header
  support behind a gateway sets this one to a stable id.
- **The check.** Read the conversation list over the real API, filtered on
  the channel the key binds to. If two requests on one key made two
  conversations, the header did not survive.

```bash
curl -H "Authorization: Bearer ftn_..." \
  "https://your-fountain/api/conversations?channel_id=openai:chat-42"
```

## Retries and timeouts

Fountain refuses a request on a thread that runs a turn now, with `409`
and `Retry-After`. It does not queue it. Set the gateway to zero retries on
this upstream, so the client sees the `409` and honours `Retry-After`. A
gateway retry sends the same prompt again at a thread that is mid-turn, and
gets the same `409`.

Set the upstream timeout with a turn in mind. A turn can take minutes. With
`stream: true` the bytes keep the connection alive. The sandbox's setup stages
and the agent's tool use stream as `reasoning_content`, which LiteLLM passes
through to the client.

## What comes back

The completion is what the [OpenAI-compatible API](openai-compatible.md#what-comes-back)
returns, through the gateway. Two fields deserve a note in a gateway.

- `usage` is zeros on every completion. Fountain bills a turn in seconds,
  not tokens. A gateway's spend dashboard shows the calls and no cost. Meter
  spend on Fountain's side, with [`/api/usage`](../api.md).
- The `fountain` object, with the `conversation_id`, `turn_id` and `thread`,
  is not a standard field. A gateway may drop it. The real API, filtered on
  the channel, is the reliable way back to the conversation.

## What it does not do

- Tool calls from the sandbox. The agent's own tools run in the sandbox, and
  the result is in the text. Only the tools that the request carries come
  back as `tool_calls`, and a gateway passes those through as it does for
  any model. Read [Your tools](openai-compatible.md#your-tools).
- Token counts. A gateway that budgets on tokens sees zero from this
  upstream.
- A gateway on the sandbox side. To point the agent's *runtime* at a
  gateway is an environment variable on the agent's environment. Read
  [LLM integration](../llm-integration.md).
