# Fountain behind LiteLLM

This example registers every Fountain agent as a model in a LiteLLM gateway.
It also verifies that multiple turns keep using one Fountain conversation.

The endpoint is alpha and requires the `openai_compat` feature flag. On a
self-hosted instance, set `FEATURE_FLAGS_ON=openai_compat`.

```bash
cp .env.example .env
# Set FOUNTAIN_URL and FOUNTAIN_API_KEY in .env.
docker compose up -d

curl localhost:4000/v1/models \
  -H "Authorization: Bearer sk-local"

python3 -m venv .venv
. .venv/bin/activate
pip install openai

OPENAI_BASE_URL=http://localhost:4000/v1 \
OPENAI_API_KEY=sk-local \
FOUNTAIN_URL=https://managoat.com/v1 \
FOUNTAIN_API_KEY=ftn_... \
python smoke.py fountain/reflex-1
```

The smoke test checks the gateway's model list, sends two turns with the same
`X-Fountain-Thread`, verifies that the second turn remembers the first, and
queries Fountain's API to confirm both turns landed in one conversation. It
also checks the body-level `safety_identifier` fallback.

The important settings are explained in
[Put Fountain behind an AI gateway](https://managoat.com/docs/integrations/gateways).
