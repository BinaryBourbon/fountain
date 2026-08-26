# litellm-gateway

Fountain behind an LLM gateway. [LiteLLM](https://github.com/BerriAI/litellm)
is the proxy here, but the shape is the same for Portkey, Kong AI Gateway,
Cloudflare AI Gateway, Bifrost or anything else that routes `model` names to
OpenAI-compatible upstreams: Fountain is one more upstream, its
[OpenAI-compatible API](https://managoat.com/docs/integrations/openai-compatible)
is the wire, and every agent on the account is a model. People who already
call the gateway call `fountain/pr-reviewer` and are talking to an agent that
runs for as long as it needs to in a sandbox of its own.

```
  any OpenAI client ──▶  LiteLLM proxy :4000        ──▶  Fountain /v1              ──▶  sandbox
    model = fountain/pr-reviewer   fountain/* → openai/*     model = pr-reviewer          the agent
    X-Fountain-Thread: chat-42     (header forwarded)        channel openai:chat-42
```

Three files are the whole integration. `config.yaml` is the LiteLLM config,
`docker-compose.yml` runs it, and `smoke.py` proves the two things that
matter through a gateway.

The endpoint is alpha, behind the `openai_compat` flag. On the hosted
platform ask for it on your account; self-hosted, set
`FEATURE_FLAGS_ON=openai_compat`.

```bash
cp .env.example .env                      # FOUNTAIN_URL, FOUNTAIN_API_KEY (`fountain keys create litellm`), LITELLM_MASTER_KEY
docker compose up -d
curl localhost:4000/v1/models -H "Authorization: Bearer sk-local"   # your agents, as fountain/<name>

pip install openai
OPENAI_BASE_URL=http://localhost:4000/v1 OPENAI_API_KEY=sk-local \
FOUNTAIN_URL=https://managoat.com/v1 FOUNTAIN_API_KEY=ftn_... \
python smoke.py fountain/reflex-1
```

## What the config does, and why

- **One wildcard, the whole account.** `model_name: "fountain/*"` maps to
  `openai/*` at `FOUNTAIN_URL`. `fountain/pr-reviewer` on the gateway is
  `pr-reviewer` on Fountain, and an agent you create tomorrow is routable
  with no restart. `check_provider_endpoint: true` fills the gateway's
  `/v1/models` from Fountain's list, so a chat client's picker shows the
  agents rather than the bare wildcard. The commented alias entry is the
  other shape: a fixed name (`support`) that hides which agent answers.
- **`forward_client_headers_to_llm_api: true`.** This is the line that
  matters. Fountain keeps a chat in one sandbox by a thread key, and the key
  is the `X-Fountain-Thread` header. LiteLLM forwards `x-` headers only when
  told to. Fountain's body-level fallback, the `user` field, does **not**
  survive LiteLLM: its OpenAI parameter list no longer has `user` (nor
  `metadata`), and it drops both before the upstream call, `drop_params` or
  not. What it does forward is `safety_identifier`, OpenAI's replacement for
  `user`, which Fountain reads as the third key. So a client that cannot set
  headers sets that. A client that sets none gets a 400 that names the
  header; Fountain never spawns a sandbox per message.
- **Long timeouts, no retries.** A turn is minutes, not seconds, and the
  first request on a thread also provisions a sandbox. `num_retries: 0`
  because the one refusal a gateway would retry, 409 `thread_busy`, carries
  `Retry-After` for the *client* to honour; a gateway retry would only
  hammer a thread that is mid-turn.
- **`drop_params: true`.** Fountain ignores `temperature` and friends. There
  is no model to sample from, and a strict client should not fail for
  sending them.

## What to notice while `smoke.py` runs

- The gateway's `/v1/models` right after boot may show only `fountain/*`.
  LiteLLM fetches Fountain's list on its own schedule (the first fetch at
  boot failed once with an SSL EOF in our smoke); the next call fills it.
- The sandbox's provisioning stages stream dim on stderr as
  `reasoning_content`. LiteLLM passes the field through, so Open WebUI or
  LibreChat behind the same proxy show it as the model's thoughts.
- The second turn on the thread answers in seconds and remembers the
  first. `smoke.py` then reads Fountain's real API
  (`GET /api/conversations?channel_id=openai:<thread>`) to show that both
  turns landed in **one** conversation. That read is the check a gateway
  integration owes: not "did I get text back", but "did the header survive".
- The `fountain` object on the completion (`conversation_id`, `turn_id`,
  `thread`) is a non-standard field. Whether a gateway preserves it is the
  gateway's business; the real API is the reliable way back to the
  conversation, which is why the script uses it.
- `usage` is zeros on every completion, on purpose. Fountain bills a turn in
  seconds, not tokens, so a gateway's spend dashboard shows the calls and
  not a cost. Meter spend on Fountain's side
  ([`/api/usage`](https://managoat.com/docs/api)).

## Other gateways

The same three settings have a name on each of them: an OpenAI-compatible
upstream at `https://your-fountain/v1` with the Fountain key, pass-through
of custom request headers (or a `user` field the gateway leaves alone), and
an upstream timeout of at least a few minutes. Anything that speaks
`/v1/chat/completions` to its upstreams can front Fountain.
