# API reference

Fountain exposes a REST API. All endpoints are under `/api/` and return JSON.

The authoritative, always-current reference is the served OpenAPI spec:

- `GET /api/openapi.json` - OpenAPI 3.1 spec, generated from the code (public, no auth)
- `GET /api/docs` - Swagger UI over the same spec

The endpoint listings below are a convenience summary of that spec.

## Authentication

**API key (recommended for scripts and CI):**

Create a key under Account -> API Keys (or exchange credentials via `POST /api/auth/token`, which is what `fountain auth login` does), then pass it as a Bearer token:

```bash
curl -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
     https://founta.inevitable.fyi/api/agents
```

```
POST   /api/auth/token             # email + password -> a fresh API key
GET    /api/auth/me                # identity of the authenticated user
POST   /api/auth/api-keys          # create a key (plaintext returned once)
DELETE /api/auth/api-keys/:id      # revoke a key
```

**Session cookie:** Obtained via OAuth at `/auth/oauth/:provider` or email/password login. Used by the web UI.

## Rate limiting

Requests are rate-limited per API key (or IP for unauthenticated requests). On limit hit: `429 Too Many Requests` with `Retry-After` header.

## Agents

```
GET    /api/agents              # list (supports ?search=, ?runtime=)
POST   /api/agents              # create
GET    /api/agents/:id
PUT    /api/agents/:id
DELETE /api/agents/:id
```

## Environments

```
GET    /api/environments
POST   /api/environments
GET    /api/environments/:id
PUT    /api/environments/:id
DELETE /api/environments/:id
GET    /api/environments/:id/secrets          # keys + timestamps only
POST   /api/environments/:id/secrets          # upsert
DELETE /api/environments/:id/secrets/:key
```

Secret values are **write-only**: once stored, the API never returns them. Listing returns each secret's key, id, and timestamps.

## Vaults

```
GET    /api/vaults
POST   /api/vaults
GET    /api/vaults/:id
PUT    /api/vaults/:id
DELETE /api/vaults/:id
GET    /api/vaults/:id/secrets                # keys + timestamps only
POST   /api/vaults/:id/secrets
DELETE /api/vaults/:id/secrets/:key
```

The same write-only rule applies to vault secret values.

## Conversations

Conversations are multi-turn: create one with an initial prompt, then keep prompting it.

```
GET    /api/conversations
POST   /api/conversations                  # start (agent_id; optional vault_id, prompt, images)
GET    /api/conversations/:id
DELETE /api/conversations/:id
POST   /api/conversations/:id/prompts      # follow-up turn
POST   /api/conversations/:id/interrupt    # stop the running turn
POST   /api/conversations/:id/terminate    # end the conversation and sandbox
GET    /api/conversations/:id/turns
GET    /api/conversations/:id/stream       # SSE log stream
```

## Error responses

```json
{"error": "not_found", "message": "Agent not found"}
```

| Status | Meaning |
|---|---|
| `400` | Invalid request body |
| `401` | Missing or invalid auth |
| `403` | Wrong tenant |
| `404` | Not found |
| `422` | Validation error |
| `429` | Rate limited |
| `500` | Internal error |

## LLM-native discovery

- `/llms.txt` - concise API summary
- `/llms-full.txt` - full API reference
- `/skill` - drop-in skill for Claude Code, Cursor, Continue, Aider

See [LLM integration](llm-integration.md) for details.
