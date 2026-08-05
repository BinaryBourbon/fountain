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
     https://your-fountain.example.com/api/agents
```

```
POST   /api/auth/token             # email + password -> a fresh API key
GET    /api/auth/me                # identity of the authenticated user
POST   /api/auth/api-keys          # create a key (plaintext returned once)
DELETE /api/auth/api-keys/:id      # revoke a key
```

**Session cookie:** Obtained via OAuth at `/auth/oauth/:provider` or email/password login. Used by the web UI.

## Inference credentials

Conversations run on your own provider tokens (BYO — Fountain never sees your inference traffic), so a new account cannot start a conversation until at least one is set.

```
GET    /api/account/inference-credentials             # per-provider set/not-set
PUT    /api/account/inference-credentials/:provider   # {"value": "...", "validate": true}
DELETE /api/account/inference-credentials/:provider   # clear
```

Providers: `anthropic_api_key`, `claude_code_oauth_token`, `openai_api_key`, `gemini_api_key`.

`PUT` pings the provider to check the credential before storing it. The outcomes are distinguishable so a client knows whether to re-type or retry:

| Status | Meaning |
|---|---|
| `200` | Stored (encrypted under your tenant key) |
| `422` | `invalid` — the provider rejected it (`provider_status` carries the upstream code); or a blank value; or an unknown provider |
| `502` | `network` — the provider was unreachable from this instance |
| `504` | `timeout` — the provider did not answer in time |

Send `{"validate": false}` to store a credential without the ping.

Values are **write-only** — these endpoints report only whether a provider is set. They require a `full`-scoped key: the per-conversation token a sandbox holds cannot read or replace the account's credentials.

## Rate limiting

Requests are rate-limited per client IP (authenticated or not — the limiter does not key by API key). On limit hit: `429 Too Many Requests` with `Retry-After` header.

## Agents

```
GET    /api/agents              # list (?search=, ?runtime=, ?environment_id=, ?has_skills=, ?has_mcp=)
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

## Bulk apply

```
POST   /api/apply                # apply a compiled manifest in one request
```

Takes the compiled form of a `fountain.yml` manifest — this is what `fountain apply` sends:

```json
{
  "resources": [
    {"kind": "Environment", "name": "proj", "spec": {"setup_script": "...", "secrets": {"TOKEN": "..."}}},
    {"kind": "Vault", "name": "alice", "spec": {"secrets": {"GH": "..."}}},
    {"kind": "Agent", "name": "researcher", "spec": {"model": "...", "runtime": "claude", "environment": "proj"}}
  ]
}
```

Resources are upserted by name in a fixed order (environments, then vaults, then agents), so an agent's `spec.environment` name reference resolves against environments in the same manifest **or** environments that already exist. Application is best-effort per resource: the response is always `200` with a per-resource result — `action` of `created`, `updated`, or `error` (with changeset-style `errors`), plus per-key secret outcomes. Secret values are never echoed back.

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
GET    /api/conversations/:id/stream       # SSE log stream (?streams=stdout,stderr,stage  ?wait=false)
```

## Error responses

```json
{"error": "not_found", "message": "Agent not found"}
```

| Status | Meaning |
|---|---|
| `400` | Invalid request body |
| `401` | Missing or invalid auth |
| `402` | Active subscription required (`subscription_required`, includes `upgrade_url`) |
| `403` | Wrong tenant |
| `404` | Not found |
| `410` | Conversation terminated (`conversation_terminated`) — stop retrying |
| `422` | Validation error |
| `429` | Rate limited |
| `500` | Internal error |

## LLM-native discovery

- `/llms.txt` - concise API summary
- `/llms-full.txt` - full API reference
- `/skill` - drop-in skill for Claude Code, Cursor, Continue, Aider

See [LLM integration](llm-integration.md) for details.
