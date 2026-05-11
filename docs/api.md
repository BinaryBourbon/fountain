# API reference

Fountain exposes a REST API. All endpoints are under `/api/v1/` and return JSON.

## Authentication

**API key (recommended for scripts and CI):**

Create a key under Account -> API Keys, then pass it as a Bearer token:

```bash
curl -H "Authorization: Bearer ft_your_api_key" \
     https://founta.inevitable.fyi/api/v1/agents
```

**Session cookie:** Obtained via GitHub OAuth at `/auth/github`. Used by the web UI.

## Rate limiting

Requests are rate-limited per API key (or IP for unauthenticated requests). On limit hit: `429 Too Many Requests` with `Retry-After` header.

## Agents

```
GET    /api/v1/agents              # list (supports ?search=, ?runtime=)
POST   /api/v1/agents              # create
GET    /api/v1/agents/:id
PUT    /api/v1/agents/:id
DELETE /api/v1/agents/:id
```

## Environments

```
GET    /api/v1/environments
POST   /api/v1/environments
GET    /api/v1/environments/:id
PUT    /api/v1/environments/:id
DELETE /api/v1/environments/:id
GET    /api/v1/environments/:id/secrets
POST   /api/v1/environments/:id/secrets       # upsert
DELETE /api/v1/environments/:id/secrets/:key
```

## Vaults

```
GET    /api/v1/vaults
POST   /api/v1/vaults
GET    /api/v1/vaults/:id
PUT    /api/v1/vaults/:id
DELETE /api/v1/vaults/:id
GET    /api/v1/vaults/:id/secrets
POST   /api/v1/vaults/:id/secrets
DELETE /api/v1/vaults/:id/secrets/:key
```

## Conversations

```
GET    /api/v1/conversations
POST   /api/v1/conversations          # start a run
GET    /api/v1/conversations/:id
GET    /api/v1/conversations/:id/turns
GET    /api/v1/conversations/:id/stream  # SSE log stream
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
