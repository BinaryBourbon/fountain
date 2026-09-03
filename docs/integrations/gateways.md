# Put Fountain behind an AI gateway

An AI gateway can treat Fountain as another OpenAI-compatible upstream. The
gateway routes a model such as `fountain/pr-reviewer` to Fountain's
`pr-reviewer` agent, and the agent runs in its usual sandbox.

```text
OpenAI client ──▶ gateway                 ──▶ Fountain /v1       ──▶ sandbox
 model: fountain/pr-reviewer  fountain/* → openai/*  pr-reviewer       agent
 X-Fountain-Thread: chat-42   forward header          openai:chat-42
```

This uses the alpha [OpenAI-compatible API](openai-compatible.md), behind the
`openai_compat` feature flag. The gateway needs no Fountain plugin.

## Configure LiteLLM

Create a Fountain API key for the gateway.

```bash
fountain keys create litellm
```

Set Fountain's `/v1` URL and API key. Set the timeout to 30 minutes. Disable
gateway retries. Forward client headers.

```yaml
model_list:
  - model_name: "fountain/*"
    litellm_params:
      model: "openai/*"
      api_base: "os.environ/FOUNTAIN_URL"
      api_key: "os.environ/FOUNTAIN_API_KEY"
      timeout: 1800
      stream_timeout: 1800
      num_retries: 0

general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  forward_client_headers_to_llm_api: true

litellm_settings:
  check_provider_endpoint: true
  drop_params: true
```

`FOUNTAIN_URL` includes `/v1`, for example `https://managoat.com/v1`. The
wildcard maps every `fountain/<agent>` model to the Fountain agent with the
same name.
`check_provider_endpoint` lets LiteLLM populate its model list from Fountain's
`GET /v1/models` response.

The complete, runnable configuration is in
[`examples/litellm-gateway`](https://github.com/BinaryBourbon/fountain/tree/main/examples/litellm-gateway).

## Preserve the thread

One Fountain thread key maps to one conversation and one sandbox. Fountain
reads it from three locations in this order.

1. `X-Fountain-Thread`
2. `user`
3. `safety_identifier`

Configure the gateway to forward custom request headers. In LiteLLM,
`forward_client_headers_to_llm_api: true` carries `X-Fountain-Thread` to
Fountain. This is the best key for a client that has a distinct chat or thread
identifier.

The body fields cover clients that cannot set headers. `user` remains for
older clients. OpenAI added `safety_identifier` as one successor to the
deprecated `user` field. LiteLLM recognizes it. Both commonly identify a
person rather than a chat. Either field can give that person one long-lived
sandbox for each agent.

The LiteLLM smoke performed on 2026-08-26 found that its then-current OpenAI
parameter filter dropped `user` and forwarded `safety_identifier`. Fountain
therefore accepts both. Fountain rejects a request with none of the three. It
does not open a sandbox for every message.

To check a gateway, send two requests with the same thread header and then
query Fountain directly:

```bash
curl -H "Authorization: Bearer ftn_..." \
  "https://managoat.com/api/conversations?channel_id=openai:chat-42"
```

There should be one conversation for the channel. A text response does not by
itself prove that the gateway preserved the thread.

## Timeouts and retries

A turn may run for minutes, and the first turn may also provision a sandbox.
Use a long upstream timeout. A streamed response keeps the connection active
while Fountain sends output and lifecycle details.

Fountain returns `409` with `Retry-After` when a thread already has an active
turn. Disable gateway retries for this upstream so the client receives that
response and decides when to retry.

## Response details

- `usage` contains zero token counts because Fountain meters turns, not
  tokens.
- `reasoning_content` carries the agent's thought, tool activity, and sandbox
  setup stages.
- `fountain` is a non-standard response object. A gateway may discard it. Use
  Fountain's API to find the conversation id.
- Only caller-defined tools return as `tool_calls`. Tools the agent runs in
  its sandbox have already completed and appear in the agent's answer.

The gateway in front of Fountain is not the gateway the agent uses for
inference. Each user brings their own provider credentials. Read
[the service you do not configure](index.md#the-service-you-do-not-configure).
