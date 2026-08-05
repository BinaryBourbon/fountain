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

**Registration and account recovery** (no auth — the emailed token authenticates the completion):

```
POST   /api/auth/register          # {email, password}
POST   /api/auth/resend-verification
POST   /api/auth/verify            # {token} -> activate the account
POST   /api/auth/forgot            # {email} — always 200, never reveals whether it exists
POST   /api/auth/reset             # {token, password}
POST   /api/auth/email/confirm     # {token} — completes a pending email change
```

The verification and reset emails keep linking to the browser pages; these endpoints accept the same tokens, so a CLI can prompt "paste the code from your email" and never open a browser. `verify` is idempotent (an already-verified account is a 200) and issues no session — mint a key at `POST /api/auth/token` once the account is live. Token failures are `422` with `error` of `invalid_token` or `expired`.

Completing a reset or an email change bumps `session_version`, which signs out every existing session.

**Credential changes** (bearer token **plus** the current password; `full`-scoped keys only):

```
POST   /api/auth/password          # {current_password, new_password}
POST   /api/auth/email             # {new_email, current_password} — sends a confirmation link
```

Changing the password signs out browser sessions (`session_version` bumps) but does **not** revoke API keys — they are separate credentials with their own expiries. The response says so explicitly (`sessions_invalidated`, `api_keys_revoked`); if you are rotating because something leaked, revoke keys yourself with `DELETE /api/auth/api-keys/:id`.

The email endpoint answers identically whether or not the address is free — it is not an availability oracle — and the address only changes when the emailed token is submitted to `POST /api/auth/email/confirm`.

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

Agent objects carry `conversation_count`; environments carry `secret_count` and `agent_count`; vaults carry `secret_count`. They are on both the list and single-resource reads, so "is this environment in use / safe to delete" is one request.

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
GET    /api/conversations                  # list (?roots_only=true hides sub-conversations)
POST   /api/conversations                  # start (agent_id; optional vault_id, prompt, images)
GET    /api/conversations/:id
DELETE /api/conversations/:id
POST   /api/conversations/:id/read         # clear unread state
GET    /api/conversations/:id/tree         # the whole spawn tree this conversation belongs to
POST   /api/conversations/:id/prompts      # follow-up turn
POST   /api/conversations/:id/interrupt    # stop the running turn
POST   /api/conversations/:id/terminate    # end the conversation and sandbox
GET    /api/conversations/:id/turns
GET    /api/conversations/:id/events       # log events as JSON (?streams=  ?after=  ?limit=)
GET    /api/conversations/:id/stream       # SSE log stream (?streams=stdout,stderr,stage  ?wait=false)
```

Conversation objects carry `title`, `turn_count`, `last_active_at`, `last_read_at` and a computed `unread` alongside the lifecycle fields. `unread` is true when `last_active_at` is later than `last_read_at` (and for a conversation never read); `POST /api/conversations/:id/read` clears it.

`/tree` returns every conversation in the same spawn tree — ancestors and descendants, flat, each with a `parent_id`:

```json
{"data": [{"id": "…", "source": "ui", "status": "idle", "parent_id": null},
          {"id": "…", "source": "agent", "status": "running", "parent_id": "…"}]}
```

Since sub-conversations are created over the API (`X-Fountain-Parent-Conversation-Id`), this is how an agent that fanned out enumerates what it started without keeping its own bookkeeping.

`/events` is the read-model for the log feed and `/stream` is the tail. The JSON endpoint returns the same rows the stream sends — `kind`, `stream`, `data`, `stage`, `state`, `duration_ms`, `turn_id`, `ts` — plus each event's `id`, oldest first:

```json
{"data": [{"id": 41, "kind": "output", "stream": "stdout", "data": "...", "ts": "..."}],
 "meta": {"limit": 100, "has_more": true, "next_cursor": 41}}
```

Page by passing the previous response's `meta.next_cursor` as `after`; keep going while `meta.has_more` is true. `limit` defaults to 100 and caps at 1000. The `id` is the same value the SSE route uses as `Last-Event-ID`, so a client can drain history as JSON and then attach the stream from where it left off.

## Audit

```
GET    /api/audit    # ?limit= ?before= ?action_prefix= ?resource_type= ?since= ?until=
```

The account's own append-only trail, newest first: `id`, `inserted_at`, `actor`, `action`, `resource_type`, `resource_id`, `metadata`, `request_ip`. `actor` distinguishes `ui` (browser session), `api` (a bearer key), `sprite` (the per-conversation token a sandbox holds) and `system`.

Page backwards with `meta.next_cursor` as `before`; `limit` defaults to 100 and caps at 500. `action_prefix` matches a family of actions (`vault.`) and is treated as a literal, not a LIKE pattern. `since` / `until` take ISO 8601 timestamps and are refused with `400` if malformed rather than silently ignored.

Only this tenant's events are visible.

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
