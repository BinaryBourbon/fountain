# API reference

The full API spec lives at:

- **[/api/openapi.json](/api/openapi.json)** — OpenAPI 3 spec, generated from controller decls
- **[/api/docs](/api/docs)** — Swagger UI; click "Authorize" to set your bearer token and try calls inline

Everything under `/api/*` requires `Authorization: Bearer <FOUNTAIN_API_KEY>`. Mint one with `fountain auth login` (writes to `~/.fountain/credentials`) or `fountain keys create` (prints a raw key for scripting).

## Endpoint summary

| method | path | what |
| --- | --- | --- |
| GET | `/api/agents` | list all |
| POST | `/api/agents` | create |
| GET | `/api/agents/:id` | one |
| PUT | `/api/agents/:id` | update |
| DELETE | `/api/agents/:id` | delete |
| GET | `/api/environments` | list all |
| POST | `/api/environments` | create |
| PUT | `/api/environments/:id` | update |
| DELETE | `/api/environments/:id` | delete |
| POST | `/api/environments/:id/secrets` | add a secret |
| DELETE | `/api/environments/:id/secrets/:key` | remove |
| GET | `/api/conversations` | list all |
| POST | `/api/conversations` | start a new conversation (provisions a sprite, queues turn 1) |
| GET | `/api/conversations/:id` | one |
| GET | `/api/conversations/:id/stream` | SSE event stream |
| POST | `/api/conversations/:id/prompts` | send a follow-up prompt (turn 2+) |
| POST | `/api/conversations/:id/interrupt` | stop the running turn, keep the sandbox |
| POST | `/api/conversations/:id/terminate` | destroy the sprite |
| DELETE | `/api/conversations/:id` | destroy + remove DB row |

## Stream params

`GET /api/conversations/:id/stream` accepts:

- **`?streams=stdout,stderr,stage`** — comma-separated allow-list of event categories. Empty/missing = all. Unknown values = nothing.
- **`?wait=false`** — close immediately after replaying buffered events. Default keeps the stream open for live tailing (closes after ~60s of no activity).
- **`Last-Event-ID: <int>`** header — resume after this id; replay everything newer.

## Response envelope

All non-stream endpoints return:

```json
{ "data": { ... } }
```

or for lists:

```json
{ "data": [ { ... }, { ... } ] }
```

Errors come back with appropriate HTTP status and a body shaped like:

```json
{ "errors": [{"title": "...", "message": "...", "source": {"pointer": "/field"}}] }
```
