# API reference

Fountain serves a REST API. Each endpoint sits under `/api/`, and each one
returns JSON.

!!! tip "Do you write a script, and not an integration?"

    The [TypeScript SDK](sdk.md) is one call over the conversation endpoints
    below, `fountain.run(prompt, { agent, vault })`.

    Reach for the raw API when you need a surface the SDK does not wrap, or a
    language nobody wrote it in.

The authority is the OpenAPI spec that the server serves. It is always
current.

- `GET /api/openapi.json`, the OpenAPI 3.1 spec, generated from the code. It
  is public, and it needs no auth.
- `GET /api/docs`, a Swagger UI over that same spec.

The endpoint lists below summarise that spec, for convenience. Each `/api/`
endpoint is in the spec, and the auth surface with them.

A test walks the router, and fails when somebody adds a route with no spec
entry. So a generated client covers the whole API. It does not cover the parts
that somebody remembered to document.

## Authentication

**An API key. Use this for a script and for CI.**

Create a key under Account, then API Keys. Or exchange your credentials at
`POST /api/auth/token`, which is what `fountain auth login` does. Then pass
the key as a Bearer token.

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

**Registration and account recovery.** These need no auth. The token in the
email authenticates the last step.

```
POST   /api/auth/register          # {email, password}
POST   /api/auth/resend-verification
POST   /api/auth/verify            # {token} -> activate the account
POST   /api/auth/forgot            # {email}. Always 200, never reveals whether it exists
POST   /api/auth/reset             # {token, password}
POST   /api/auth/email/confirm     # {token}. Completes a pending email change
```

The verification and reset emails still link to the browser pages. These
endpoints accept the same tokens, so a CLI can ask you to paste the code from
your email, and open no browser.

`verify` is idempotent, so an account somebody already verified gets a 200. It
issues no session, so mint a key at `POST /api/auth/token` once the account is
live. A token failure is a `422`, with an `error` of `invalid_token` or
`expired`.

A reset that completes bumps `session_version`, and so does an email change
that completes. That signs out each session that exists.

**Credential changes.** These need the bearer token **and** the current
password. They take a `full`-scoped key alone.

```
POST   /api/auth/password          # {current_password, new_password}
POST   /api/auth/email             # {new_email, current_password}. Sends a confirmation link
```

A change of password signs out the browser sessions, because `session_version`
bumps. It does **not** revoke an API key. Those are separate credentials, with
their own expiries.

The response says so, in `sessions_invalidated` and `api_keys_revoked`. If you
rotate because something leaked, revoke the keys yourself, with
`DELETE /api/auth/api-keys/:id`.

The email endpoint answers the same way whether the address is free or not, so
it tells nobody which addresses exist. The address changes only when somebody
submits the emailed token to `POST /api/auth/email/confirm`.

**A session cookie.** You get one from OAuth at `/auth/oauth/:provider`, or
from an email and password login. Fountain's own console uses it.

### Sign in with Fountain (OAuth 2.0 for browser apps)

Fountain's own browser apps sit on other origins. Those are
[team](https://github.com/jhgaylor/fountain-team) and
[conversations](https://github.com/jhgaylor/fountain-conversations), and
neither pastes a key.

They use the **authorization code grant with PKCE (S256)**, as public
clients. The token they get *is* an API key (`decisions/0021`).

```
GET  /oauth/authorize?client_id=…&redirect_uri=…&code_challenge=…&code_challenge_method=S256&state=…
     # browser: consent page (login round-trips back here) → 302 redirect_uri?code=…&state=…
POST /api/oauth/token    # {grant_type: "authorization_code", code, code_verifier, client_id, redirect_uri}
                         # → {access_token, token_type: "bearer", expires_in}   (400 invalid_grant otherwise)
POST /api/oauth/revoke   # bearer: revoke the presented token (sign-out)
```

A client or a redirect that nobody registered renders an error page, and
Fountain redirects nowhere.

A code lives five minutes, and it works once. The key is full-scope, it
expires in 30 days, and it lists under Account, then API keys, as
`oauth:<client_id>`.

### Register your own app

You do not have to ask an operator to add your app to `OAUTH_CLIENTS`. Any
account can register a client for itself, in the console under Account, then
OAuth apps, with `fountain oauth-client create`, or over the API.

```
GET    /api/oauth/clients        # the account's clients
POST   /api/oauth/clients        # {name, redirect_uris} -> {client_id, ...}
GET    /api/oauth/clients/:id
PATCH  /api/oauth/clients/:id    # rename, or replace the redirect URIs
DELETE /api/oauth/clients/:id
```

These routes need a full-scope key. A conversation-scoped sandbox token
cannot register a client, for the same reason it cannot mint an API key.

Your client starts in **development mode**. It signs in the account that
registered it, and every other account gets an error page instead of a
redirect. That boundary is why you can name any redirect URI you like, such as
a sandbox's public URL or a port on your own machine. Only an operator can
publish a client, which is what lets other accounts sign in to it.

A redirect URI must match exactly, and must be `https`, unless the host is
`localhost` or `127.0.0.1`. A loopback URI matches on any port, so a dev
server that moves from 5173 to 5174 still works.

A registered client's redirect origins can also call `/api` from a browser.
So one registration covers the sign-in and the CORS allowance, and neither
needs `OAUTH_CLIENTS` nor `API_CORS_ORIGINS`.

## Account state

```
GET    /api/account/onboarding           # {state, completed, completed_at}
POST   /api/account/onboarding/complete  # idempotent
```

An account that somebody configured through the API alone never passes through
the browser wizard. So nothing marks it onboarded, and a later browser visit
re-enters that wizard. Complete it over the API and the loop closes.

`GET /api/auth/me` also carries `email_verified`, `onboarding_state` and
`onboarding_completed`.

### Billing

```
GET    /api/account/billing                   # balance, cap, current-month usage
POST   /api/account/billing/credits/checkout  # Stripe Checkout URL for a credit pack
```

Stripe needs a browser to finish, so the URL is what you get. Mint it here,
and open it there. The server chooses the return URLs. A URL that a caller
supplied would be an open redirect.

`credits/checkout` returns a one-time Stripe Checkout URL for a credit pack.
The balance moves when Stripe's webhook confirms the payment.

The checkout refuses a comped account with `422`. It answers `502` when
Stripe is unreachable, and guesses nothing. On an instance with payment off,
both endpoints are a `404` with `"billing": "disabled"`.

`GET /api/account/billing` reports the month as `usage`. The `conversations`
count is the conversations that ran a turn in the month. The
`credit_burned_cents` value is the credit the ledger took in the month, and
`turn_hours` is the metered time. The two do not agree to the cent, because the
pricer charges a turn when it ends.

`GET /api/auth/me` carries `comped`. It is `true` for an account an operator
made free, and `null` when payment is off. It also carries `brokered`. It is
`true` when the account runs behind the egress credential broker. See
[Secrets](concepts/secrets.md).

### Data export and deletion

```
POST   /api/account/exports              # 202 with a pending export; 429 + Retry-After inside the hour
GET    /api/account/exports              # status (zero- or one-element list)
GET    /api/account/exports/:id
GET    /api/account/exports/:id/download # gzipped JSON
DELETE /api/account                      # {"confirm": "<your account email>"}. Irreversible
```

An export builds in the background, and the API has no PubSub. So poll
`GET /api/account/exports` until `downloadable` is true. One account holds one
export at most, and takes one request each hour.

To delete the account destroys the sandboxes, and
removes each resource **and the tenant encryption key**. It needs the
confirmation body, which is the API's version of the typed-email gate in the
UI. It also needs a `full`-scoped key.

## Inference credentials

A conversation runs on your own provider token, and Fountain never sees your
inference traffic. So a new account cannot start a conversation until you set
at least one.

```
GET    /api/account/inference-credentials             # per-provider set/not-set
PUT    /api/account/inference-credentials/:provider   # {"value": "...", "validate": true}
DELETE /api/account/inference-credentials/:provider   # clear
```

The providers are `anthropic_api_key`, `claude_code_oauth_token`,
`openai_api_key` and `gemini_api_key`.

`PUT` pings the provider to check the credential before it stores it. The
outcomes differ, so a client knows whether to ask for the value again or to
try again.

| Status | Meaning |
|---|---|
| `200` | Stored, encrypted under your tenant key. |
| `422` | `invalid`. The provider rejected it, and `provider_status` carries the upstream code. Or the value was blank. Or nobody knows that provider. |
| `502` | `network`. This instance could not reach the provider. |
| `504` | `timeout`. The provider did not answer in time. |

Send `{"validate": false}` to store a credential with no ping.

A value is **write-only**, so these endpoints report which providers hold one,
and no more. They need a `full`-scoped key, because the token a sandbox holds
for one conversation can neither read nor replace the account's credentials.

## Rate limiting

Fountain rate-limits a request by client IP, whether it carries auth or not.
The limiter does not key on the API key. On a limit you get
`429 Too Many Requests`, with a `Retry-After` header.

## Agents

```
GET    /api/agents              # list (?search=, ?runtime=, ?environment_id=, ?has_skills=, ?has_mcp=)
POST   /api/agents              # create
GET    /api/agents/:id
PUT    /api/agents/:id
DELETE /api/agents/:id
```

```
GET    /api/agents/:id/versions            # config history, newest first
GET    /api/agents/:id/versions/:version   # one version, with its full config
```

Fountain writes a version each time an agent's config changes. Version 1 is
the config at create time. Each version carries the full config
and a `version` number. The API serves versions as read-only data. A rollback
is a console action.

```
GET    /api/agents/:id/avatar   # image bytes (bearer token)
PUT    /api/agents/:id/avatar   # raw bytes with an image content-type, or {"data": base64, "media_type": ...}
DELETE /api/agents/:id/avatar
```

An avatar takes `image/png`, `image/jpeg`, `image/gif` or `image/webp`, up to
5 MB. The agent object carries `avatar_media_type`, which is null when there
is no avatar.

Fountain refuses another type with `415`, and an upload that is too large with
`413`. It serves the bytes with `nosniff` and a CSP that sandboxes them, and it
checks the media type again at serve time.

An agent object carries `conversation_count`. An environment carries
`secret_count` and `agent_count`. A vault carries `secret_count`.

An agent carries `sandbox_mode`, which is `ephemeral` or `persistent`. With
`ephemeral`, each conversation gets a sandbox of its own. With `persistent`,
the agent has one machine, and each conversation with the same environment
and vault lands on it. That machine survives a conversation that ends, and
nothing stops it while it runs. A launch can name the
other mode with `sandbox_mode` on `POST /api/conversations`.

They are on the list read and on the single-resource read. So "does this
environment have a user, and is it safe to delete" is one request.

## Catalog

```
GET  /api/catalog             # runtimes, model suggestions per runtime, sandbox providers, package managers, avatar bases/moods, app URLs
POST /api/avatars/generate    # {base, mood} → {data (base64 PNG), media_type}; attach with PUT /api/agents/:id/avatar
```

This is the vocabulary that builds the agent and environment forms. A client
somewhere else can read it, and hard-code nothing.

A model list is a set of suggestions, and not an allowlist. Fountain accepts
any `provider/model` under a provider it knows.

`package_managers` names what Fountain installs from an environment's
`packages`, which is `apt` and `npm`. It stores another key and ignores it.

To draw an avatar, Fountain uses the tenant's own OpenAI credential. Without
one it answers `422 no_openai_key`.

`apps` is where this instance sends a person to *read* something. Those are
the standalone
[conversations](https://github.com/jhgaylor/fountain-conversations) and
[team](https://github.com/jhgaylor/fountain-team) apps, which route on the
fragment, as `…/#/c/<conversation_id>` and `…/#/team/<agent_id>`.

Either one is null where the deployment has no such app. Use `apps`, and do
not compose a URL against the API host. Fountain's own UI is a console, and it
serves no transcript.

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

A secret value is **write-only**. Once Fountain stores it, the API never
returns it. A list returns each secret's key, its id, and its timestamps.

## Vaults

```
GET    /api/vaults
POST   /api/vaults
GET    /api/vaults/:id
PUT    /api/vaults/:id
DELETE /api/vaults/:id
GET    /api/vaults/:id/secrets                # keys, timestamps, expiry only
POST   /api/vaults/:id/secrets
DELETE /api/vaults/:id/secrets/:key
```

The same write-only rule covers a vault secret value.

## Secret bindings

<!-- vale STE.IngForms = NO -->
Limited access. These routes answer only when the credential broker is on
for the account. Read [Feature status](reference/feature-status.md), and
[Where a secret comes from](concepts/secrets.md#bindings-when-the-broker-is-on)
for what a binding does.

```
GET    /api/secret-bindings                # each binding: secret name, host, shape
GET    /api/secret-bindings/presets        # the shapes a binding can take
POST   /api/secret-bindings
PATCH  /api/secret-bindings/:id
DELETE /api/secret-bindings/:id
```

A binding is about the name of a secret, so it applies to every environment
and vault that holds a secret of that name. A conversation-scoped token
cannot reach these routes. They need a full-scope key.
<!-- vale STE.IngForms = YES -->

## Bulk apply

```
POST   /api/apply                # apply a compiled manifest in one request
```

This takes the compiled form of a `fountain.yml` manifest, which is what
`fountain apply` sends.

```json
{
  "resources": [
    {"kind": "Environment", "name": "proj", "spec": {"setup_script": "...", "secrets": {"TOKEN": "..."}}},
    {"kind": "Vault", "name": "alice", "spec": {"secrets": {"GH": "..."}}},
    {"kind": "Agent", "name": "researcher", "spec": {"model": "...", "runtime": "claude", "environment": "proj"}}
  ]
}
```

Fountain upserts a resource by name, in a fixed order. Environments first,
then vaults, then agents. So an agent's `spec.environment` name reference
resolves against an environment in the same manifest, **or** against one that
already exists.

Fountain applies each resource on a best-effort basis. The response is always
a `200`, with one result for each resource. Each result carries an `action` of
`created`, `updated` or `error`, and an `error` carries changeset-style
`errors`. Each result also carries the outcome for each secret key. Fountain
never echoes a secret value back.

## Conversations

A conversation takes many turns. Create one with a first prompt, then prompt
it again and again.

```
GET    /api/conversations                  # list (?roots_only=true; ?agent_id= ?channel_id= ?status=idle,terminated)
POST   /api/conversations                  # start (agent_id; optional vault_id, environment_id, sandbox_id, sandbox_mode, prompt, images)
GET    /api/conversations/:id
DELETE /api/conversations/:id
POST   /api/conversations/:id/read         # clear unread state
POST   /api/conversations/:id/requests/:request_id   # answer a permission request ({option_id})
GET    /api/conversations/:id/tree         # the whole spawn tree this conversation belongs to
POST   /api/conversations/:id/prompts      # follow-up turn
POST   /api/conversations/:id/interrupt    # stop the running turn
POST   /api/conversations/:id/terminate    # end the conversation; destroys the sandbox unless it is persistent or shared
GET    /api/conversations/:id/turns
GET    /api/conversations/:id/events       # log events as JSON (?streams=  ?after=  ?limit=)
GET    /api/conversations/:id/stream       # SSE log stream (?streams=stdout,stderr,stage  ?wait=false)
GET    /api/conversations/:id/turns/:turn_id/images/:position   # image bytes
GET    /api/conversations/:id/egress       # what left the sandbox through the broker (limited access)
```

<!-- vale STE.IngForms = NO -->
`GET /api/conversations/:id/egress` is there only when the credential broker
is on for the account. Read [Feature status](reference/feature-status.md). It
lists each request that left the sandbox through the broker, with the host,
the binding that matched, the status and the latency. A refused host shows
the refusal. The list stays for `BROKER_LOG_RETENTION_HOURS` after the
conversation ends.
<!-- vale STE.IngForms = YES -->

A turn carries `image_count`. The image endpoint takes a `position` into that
count, which starts at zero, and returns the raw bytes with the stored media
type.

A turn also carries `origin`. It is `user` for a prompt that somebody sent.
It is `autonomous` for a turn that the server opened for a background cycle
of the agent, after the answer to its prompt. In that case `prompt` holds a
marker, not the words of a person.

`sandbox_id` attaches the new conversation to a sandbox you already have.
Fountain then provisions nothing. The sandbox must be `ready` or `suspended`,
and Fountain must have built it for the same agent, environment and vault.
Otherwise you get `404 sandbox_not_found`, `409 sandbox_not_attachable` or
`422 sandbox_identity_mismatch`. Several conversations can then run on one
disk at the same time. On an opencode or gemini sandbox, only one turn runs
at a time. A second prompt gets `409 sandbox_at_capacity` while the first
one runs.

`sandbox_mode` is `ephemeral` or `persistent`, and it replaces the agent's
default for this conversation. A persistent conversation lands on the agent's
own machine. Fountain makes that machine on the first persistent launch of an
agent, environment and vault. A second launch while the first still builds
it gets `503 provisioning`, so send again shortly.

`POST /api/conversations/:id/requests/:request_id` answers a permission
request that blocks the agent. The request and its options arrive as a
`permission_request` block on the event stream. Send `{option_id}`, and
choose one of the `optionId` values that the block carried. The first answer
wins. A request that another client, the timeout or the end of the turn
resolved gets `409 permission_request_resolved`. An option the agent did not
offer gets `422 unknown_option`. A sandbox's own token cannot answer, and
gets `403 sprite_may_not_answer`.

Whatever does not resolve is a `404`, so nobody can probe for an id.

That covers four cases. A conversation nobody knows. A turn from a different
conversation. A position that is not there. A stored media type that is not an
image.

The list takes three filters, and you can combine each of them with
`roots_only`.

`agent_id`. `channel_id`, which names the channel that holds a conversation,
and the team's is `fountain:team`. Remove a teammate and its conversation comes
free, so it no longer matches. A teammate's full history is therefore
`GET /api/team/:agent_id/conversations`.

`status`, which takes a comma-separated list. A value outside the vocabulary
gives a `400 invalid_status`.

The list has no pages.

A conversation object carries `title`, `turn_count`, `last_active_at`,
`last_read_at` and a computed `unread`, next to the lifecycle fields.

`unread` is true when `last_active_at` is later than `last_read_at`, and for a
conversation that nobody read. `POST /api/conversations/:id/read` clears it.

**Token usage.** Each turn carries `usage`, as
`{input, output, cache_read?, cache_write?}`. That is the figure the runtime
reports when the turn ends, in the `usage` of the ACP `session/prompt`
response. claude-agent-acp and codex-acp report it.

It is `null` in three cases. While the turn runs. When the runtime reported
none. On a turn older than the field.

Fountain records it once for each turn. It never sums the `usage_update`
notifications that stream while a turn runs. Those report how full the context
window is, and each runtime means something different by that.

Each conversation carries `agent_version_id` and `agent_version`. They name
the agent config version that the conversation started with. Both are null
for a conversation that predates config versions. The list and get endpoints
resolve `agent_version`; other endpoints that embed a conversation return
null for it. Read the version at `/api/agents/:id/versions/:version`.

Each conversation carries `usage_total: {input, output}`, a sum over its
turns. A `/api/team` roster entry carries `usage_total` summed over each
conversation the agent has had on the team.

`/tree` returns each conversation in the same spawn tree. Ancestors and
descendants, flat, and each one with a `parent_id`.

```json
{"data": [{"id": "…", "source": "ui", "status": "idle", "parent_id": null},
          {"id": "…", "source": "agent", "status": "running", "parent_id": "…"}]}
```

A sub-conversation arrives over the API, with
`X-Fountain-Parent-Conversation-Id`. So this is how an agent that fanned out
lists what it started, and keeps no records of its own.

`/events` is the read model for the log feed, and `/stream` is the tail.

The JSON endpoint returns the rows that the stream sends, which are `kind`,
`stream`, `data`, `stage`, `state`, `duration_ms`, `turn_id` and `ts`. It adds
each event's `id`, and it returns the oldest first.

```json
{"data": [{"id": 41, "kind": "output", "stream": "stdout", "data": "...", "ts": "..."}],
 "meta": {"limit": 100, "has_more": true, "next_cursor": 41}}
```

To page, pass the previous response's `meta.next_cursor` as `after`. Continue
while `meta.has_more` is true. `limit` defaults to 100, and caps at 1000.

The `id` is the value that the SSE route uses as `Last-Event-ID`. So a client
can drain the history as JSON, then attach the stream where it stopped.

`?blocks=true` works on `/events`, on `/stream` and on
`/api/events/stream`. It adds `blocks` to each event.

That is the event's `data`, parsed on the server into the structured blocks
that a transcript renders. It is the parse the conversations app uses,
`Fountain.Conversations.Blocks`. So a client never writes a runtime's dialect
again. That is ADR 0014, applied to the wire.

Here are the kinds, and their fields.

| kind | fields |
|---|---|
| `text`, `thinking` | `body` |
| `tool_use` | `id`, `name`, `summary`, `body`, which is the input. |
| `tool_result` | `tool_id`, `body`, `error`. Pair it with the `tool_use` that has the same id. |
| `init` | `summary`, `body` |
| `result` | `body`, `raw` |
| `error` | `body` |
| `raw` | `body`, `summary`. It is a line nobody recognised. Fountain shows it, and drops nothing. |

An event that is not output carries `blocks: []`. Without the flag, the field
is absent.

### Every conversation on one stream

```
GET /api/events/stream          # SSE (?streams=  ?blocks=true)
```

This is one `text/event-stream` for each conversation the caller owns that has
not finished. A conversation list with live status and unread dots needs that,
and it needs no socket for each conversation.

Each event is the payload of the stream for one conversation, with
`conversation_id` added.

Fountain sends a `conversations` event, `{"reason":"changed"}`, when the list
changes. That is a create, a title, a read, a delete or a finish, and Fountain
sends at most one each second. The stream follows a new conversation on its
own, and the client lists them again.

`Last-Event-ID` replays what you missed, across each conversation the stream
follows. The first byte is a `: connected` comment. A heartbeat arrives every
15 s. The stream closes after 60 s idle, so the client reconnects.

## Sandboxes

A sandbox is the computer a conversation runs on. One sandbox can hold
several conversations.

```
GET    /api/sandboxes          # list (?status=ready,suspended)
GET    /api/sandboxes/:id
DELETE /api/sandboxes/:id      # reset a persistent sandbox
```

Each sandbox carries `status`, `mode`, `provider` and `url`. It also carries
the `agent_id`, `environment_id` and `vault_id` that Fountain built it for,
and `conversations`. Each entry there carries `mid_turn`, which is true while
that conversation runs a turn. To put a second conversation on a sandbox,
pass its id as `sandbox_id` to `POST /api/conversations`.

`DELETE` resets a `persistent` sandbox. Fountain destroys the machine and
keeps the conversations on it. The next prompt on one of them builds a clean
machine for the same agent, environment and vault. The response is `204`.
An ephemeral sandbox, or one that is already `terminated` or `failed`, gets
`422 sandbox_not_resettable`. While a conversation on the sandbox runs a
turn, the request gets `409 sandbox_mid_turn`.

Three other requests retire a persistent sandbox, because each one moves the
identity that the sandbox belongs to. A `PATCH /api/agents/:id` with a new
`environment_id` retires the sandboxes built on the old environment. A
`DELETE` on `/api/environments/:id` or on `/api/vaults/:id` retires the
sandboxes built on that environment or that vault. Each request behaves like
a reset. Fountain destroys the machine, keeps the conversations, and builds a
new machine on the next prompt. A request also gets `409 sandbox_mid_turn`
while a conversation on one of those sandboxes runs a turn.

## Search

This is full-text search across the caller's conversations. A command palette
uses it, to jump to a message.

```
GET /api/search?q=<text>[&limit=20][&offset=0][&agent_id=][&conversation_id=][&since=][&kinds=title,prompt,reply]
```

```json
{"data": [{"kind": "reply", "conversation_id": "…", "agent_id": "…", "turn_id": "…",
           "turn_number": 3, "snippet": "… the gate lives in the billing plug …",
           "ts": "2026-08-19T02:00:00Z"}],
 "meta": {"limit": 20, "offset": 0, "has_more": false}}
```

There are three sources, in one shape.

`title` is a conversation's title, and its `turn_id` is null. `prompt` is a
turn's prompt. `reply` is a turn's assistant text, which is the `text` blocks
of its events. Fountain materialises a reply when the turn ends, so you can
search a turn in flight by its prompt, and not yet by its reply.

It is Postgres full-text, with `websearch` syntax. That is a
`"quoted phrase"`, a `-excluded` word, and `or`. It matches an exact token and
stems nothing, so an identifier and a code fragment match as themselves.

Fountain ranks the hits, and puts the newest first among equals. The
`snippet` is plain text with no markup. The `ts` is the creation time of the
turn, or of the conversation itself. A `limit` caps at 100.

The query itself scopes each source to the caller. Fountain indexes nothing
across tenants. The rate limit on the rest of `/api` covers this too.

A turn that ended before the `reply_text` column existed is searchable by its
prompt alone. Run the one-time backfill on the server to fix that, with
`bin/fountain_server eval 'Fountain.Release.backfill_turn_replies()'`.

## Team

These routes serve the roster that [`/team`](concepts/teammates.md) shows, to
a client that is not this web app. A teammate is a conversation bound to the
reserved channel `fountain:team`.

Each route here wraps the `Fountain.Team` that the page wraps. So a standalone
client gets the page's exact semantics, and writes none of them again over
`/api/conversations`.

Those semantics are three. An add is idempotent. A message wakes a parked
machine, or opens a fresh conversation when nobody can resume the old one. A
remove terminates the conversation and unbinds it.

```
GET    /api/team                    # roster: agent, conversation, presence, unread, preview
POST   /api/team                    # add (agent_id; optional name, environment_id, vault_id)
GET    /api/team/:agent_id
PATCH  /api/team/:agent_id          # rename ({name}; null or blank → the agent's name)
DELETE /api/team/:agent_id          # remove: terminate the live conversation, unbind history
POST   /api/team/:agent_id/messages # a turn (prompt; optional images) → {conversation_id}
GET    /api/team/:agent_id/conversations  # history: every conversation on the team, newest first, `current` flagged
POST   /api/team/:agent_id/contact  # give the teammate an email address + phone number ({prompt_from_number}; flag `team_comms`)
PATCH  /api/team/:agent_id/contact  # change prompt_from_number (nothing bought or released)
DELETE /api/team/:agent_id/contact  # release them
GET    /api/team/comms              # {enabled, configured}: may this caller, and can this instance
GET    /api/team/stream             # SSE: every teammate's events on one connection (`?blocks=true`)
```

`PATCH /api/team/:agent_id` sets the teammate's name, which is its
conversation's `title`. That name carries onto the fresh conversation that
Fountain opens when nobody can resume this one. The audit trail records
`team.renamed`, and the stream sends `team`.

`GET /api/team/:agent_id/conversations` is the teammate's history. A retired
conversation is a previous machine's thread. It stays bound to the team
channel until somebody removes the teammate, so the list shows it behind the
current one, with `current: false`. Read it with
`GET /api/conversations/:id/events`.

`POST /api/team/:agent_id/conversations` starts the teammate over, and keeps
its machine.

Fountain retires the current conversation. It goes `terminated`, and the list
shows it behind the new one with `current: false`. Fountain opens a new
conversation on the same channel. That one carries the name, the environment
and the vault. It points at the **same sandbox**.

Fountain provisions nothing and interrupts nothing. The next message wakes
that sandbox through the usual reattach path, and starts a fresh runtime
session on it. So the agent's context is new, and its files, clones and
installed tools are where it left them.

You get a `201`, with the teammate and its new conversation. You get
`400 conversation_busy` while a turn runs, so interrupt it first. You get
`503 provisioning` while the machine still starts.

When the machine has gone, Fountain provisions a new sandbox instead, exactly
as `POST /api/team` would. The machine has gone when the sandbox is
`terminated` or `failed`, or when nobody can resume the conversation.

The audit trail records `team.conversation.rotated`, and the stream sends
`team`.

To retire the thread *and* the machine, the old way still works. Send
`POST /api/conversations/:id/terminate` on the current conversation. The next
message then opens a fresh one on a new sandbox.

`POST /api/team` answers `201` with the teammate. It answers `200` when the
agent was on the team already, and returns that agent's live conversation and
ignores the attributes you sent.

`name` becomes the conversation's `title`. `environment_id` and `vault_id` go
through the agent's `allowed_environment_ids` and `allowed_vault_ids`, exactly
as they do on `POST /api/conversations`. One that nobody knows, or that
belongs to another tenant, is a `404`. One the agent does not permit is a
`422`.

Each roster entry carries seven things. `name`, which is the title, or else
the agent's name. The full `agent` object. The full `conversation` object.
`presence`. `unread`. `last_turn`. `preview`, as
`{kind: "you"|"them"|"typing", text}`, or null when there are no messages.

`presence` carries a `state`, one of `working`, `starting`, `online`,
`asleep`, `away`, `machine_offline`, `failed` and `offline`. It carries a
`label` for a person to read.

`machine_offline` is a teammate on a
[self-hosted runner](integrations/runners.md) whose machine is not connected.
A message cannot wake it, and you get `503 runner_offline`. It comes back when
the daemon reconnects.

The conversation's `sandbox` carries `provider`. On a runner it also carries
`runner: {id, name, hostname, online, path}`.

**Email and phone. Alpha, behind the `team_comms` flag.** Off by default on
the hosted platform. Read [Feature status](reference/feature-status.md).

`POST /api/team/:agent_id/contact` gives the teammate an inbox, from
[AgentMail](https://agentmail.to), and a number, from
[AgentPhone](https://agentphone.ai). Both sit under the instance's own keys,
and the roster entry gains `contact: {email, phone}`.

From its next turn, the teammate holds seven MCP tools. Those are
`email_send`, `email_reply`, `email_list`, `email_get`, `sms_send`,
`sms_list` and `my_contact_info`. Fountain serves them itself, at
`POST /api/mcp/team-comms/:conversation_id`, with the conversation's sprite
token. So no provider key enters the sandbox. The audit trail records each
send as `team.contact.sent`, and never the content.

There are five refusals. You get `404 team_comms_not_enabled` when the flag is
off for the caller. You get `503 team_comms_not_configured` when the instance
holds no keys. You get `409 contact_already_provisioned` for a second contact.
You get `402 contact_limit_reached` when the account holds as many contacts
as `TEAM_CONTACT_CEILING` permits, and the body carries `count` and `limit`.
You get `424 provider_error` when a provider refuses, where `channel` names
which one. A provision is all or nothing.

`DELETE` releases both upstream, then forgets them. `GET /api/team/comms`
answers `{enabled, configured}`, so a client knows whether to offer it. Read
[configuration](configuration.md#teammate-email-and-phone).

The request body must carry `prompt_from_number`. Any common format works, and
Fountain stores E.164. It is **your** phone.

A text from that number to the teammate's number arrives as a prompt in the
teammate's conversation. AgentPhone delivers it to
`POST /api/webhooks/agentphone`, and `AGENTPHONE_WEBHOOK_SECRET` verifies the
HMAC. Fountain wraps it, so the teammate knows it came by SMS and can answer
with its `sms_send` tool.

Fountain acknowledges a text from any other number, and ignores it. It
deduplicates a delivery by AgentPhone's `X-Webhook-ID`. The audit trail
records `team.contact.prompted`, with the byte count, and never the text.

A `STOP` from that number opts it out, and so does `UNSUBSCRIBE`, `CANCEL`,
`END` or `QUIT`. Fountain sets `contact.prompt_opted_out_at`, and drops that
number's texts until a `START`, or until somebody changes the number, which is
fresh consent. Fountain answers a `HELP`.

Each keyword gets a confirmation, texted back from the teammate's number, on a
best-effort basis.

`/messages` returns `202 {status: "queued", conversation_id}`. The id names
the conversation the message went to. That is a new conversation when somebody
terminated the teammate's previous one.

You get `400 conversation_busy` while the last turn still runs. You get
`503 provisioning` while the machine starts. You get `503 runner_offline`
while the machine behind a runner-backed teammate is off.

**Teammates know each other.** Each conversation on the team channel carries
an MCP server, `fountain-team`. Fountain serves it at
`POST /api/mcp/team/:conversation_id`, and the sandbox's own token
authenticates the call. It holds four tools.

`list_teammates`.

`get_teammate`, by name, by role or by keyword, and "the engineer" resolves.

`send_to_teammate`. The message lands in their thread, with the sender named
in front. It carries a note that the owner and their teammates alone can send
such a message.

A teammate that is busy, that still starts, or whose machine is off comes back
as a tool error, so the agent can try again. The tool returns the turn it
created.

`wait_for_teammate`, which blocks for up to 90 s for the reply. `since_turn`
pins it to one turn. A `timed_out: true` means call it again.

`read_teammate`, which returns the recent prompts and replies.

So "send this to the steward", inside one teammate's turn, is two tool calls.
The team page shows the exchange in both threads.

`/stream` is one `text/event-stream` for the whole team. Each event is the
payload of the stream for one conversation, with `conversation_id` and
`agent_id` added. A client routes it to a roster row, and needs no socket for
each teammate.

Fountain sends a `team` event, `{"reason":"changed"}`, when the roster
changes. Three things change it. Somebody adds or removes a teammate. Fountain
opens a fresh conversation for one. A self-hosted runner connects or drops,
which changes presence for the teammates on it.

The stream then follows the new conversation itself, and the client lists them
again.

The stream honours `Last-Event-ID`, replayed across each teammate, and it
honours `?streams=`. A heartbeat arrives every 15 s. It closes after 60 s
idle, so the client reconnects.

### Schedules

These are the routines that the team page offers, over the API. A routine is a
cron that runs a teammate with a prompt. It runs in the teammate's own thread,
or on a one-off machine.

Each route wraps `Fountain.Team.Schedules`, so a standalone client gets the
page's exact semantics.

```
GET    /api/team/schedules                       # every schedule of the caller, soonest first
GET    /api/team/:agent_id/schedules
POST   /api/team/:agent_id/schedules             # cron (5 fields, UTC), prompt; optional name, one_off, enabled
GET    /api/team/:agent_id/schedules/:id
PATCH  /api/team/:agent_id/schedules/:id
DELETE /api/team/:agent_id/schedules/:id
POST   /api/team/:agent_id/schedules/:id/run     # run now → 202 {status: "queued", conversation_id}
```

A schedule carries `id`, `agent_id`, `name`, `cron`, `prompt`, `one_off`,
`enabled`, `next_run_at`, `last_run_at`, `last_conversation_id` and
`last_error`.

Fountain evaluates `cron` in UTC. A `0 9 * * 1-5` is 09:00 UTC on a weekday.
A name in the `@daily` style works, and `@reboot` does not.

`one_off: false` is the default. It sends the prompt into the teammate's own
conversation, as a typed message would.

`one_off: true` opens a fresh conversation on a new machine for each run. It
uses the teammate's agent, environment and vault.

The agent must be the caller's. It need not be on the team yet.

A schedule has the address `(agent_id, id)`. The same row under another
agent's path is a `404`, as another tenant's row is.

`/run` takes the path that the page's "Run now" takes, and it answers as
`/messages` does.

You get `400 conversation_busy` while the teammate's previous turn still runs.
You get `503` while its machine starts. You get `404` when the agent of an
in-thread schedule is not on the team. Fountain stamps `last_run_at` and
`last_error` either way.

The audit trail records a create, an update, a delete and a run, as
`team.schedule.*`, with the request's attribution.

The team stream sends a `schedule` event, `{"reason":"changed"}`, whenever
anybody creates, updates, deletes or fires a schedule. That holds for the API,
for the page and for the scheduler. So a client lists them again, and polls
nothing.

A browser client on another origin needs `API_CORS_ORIGINS` set on the server.
Read [configuration](configuration.md). A bearer key is the one credential
that crosses an origin.

## Support

This is "Report a problem" from a client (#843). Fountain stores the report
with whatever context the client attaches, then forwards it to the operator
out of band.

That context is the conversation, the agent, the sandbox, the presence, the
recent events, the app version and the page URL. Those are the facts that
triage needs, and never a secret.

```
POST   /api/support/reports         # {category, message, context?, client?, screenshot?} → 201 the report
GET    /api/support/reports         # the caller's reports, newest first
GET    /api/support/reports/:id
```

The `category` is one of `bug`, `stuck`, `question`, `idea` and `other`. The
`message` takes up to 20 KB. The `context` is an object of up to 64 KB. The
`client` is a string of a name and a version.

`screenshot` takes the `{data: base64, media_type}` shape that a prompt image
takes. It accepts png, jpeg, gif and webp, up to 5 MB.

The response carries `status`, which goes `new` and then `forwarded` or
`failed`. It carries `forwarded_at`, and `external_url`, which names the GitHub issue
when Fountain opened one, and `forward_error`. It reports that a screenshot is
there, and never inlines it.

The audit trail records `support.report.created`, with the category, the sizes
and the context keys. It never records the message.

An Oban job forwards the report. It opens a GitHub issue when the instance
sets `SUPPORT_GITHUB_REPO` and `SUPPORT_GITHUB_TOKEN`, which needs
issues:write, and it labels the issue `support` and the category. It mails
`SUPPORT_EMAIL`, with the screenshot attached. It can do one, the other, or
both.

Neither one configured is fine, because the rows are the inbox. The rate limit
on the rest of `/api` covers this too.

## Admin

These are for an operator account, with `role: "admin"`, that holds a
`full`-scoped key.

Each action mirrors the admin UI, and its refusals with it. Each one records
the same privilege-trail event.

```
GET    /api/admin/users                     # ?q= ?comped= ?role= ?verified= ?sort= ?dir= ?page= ?per_page=
GET    /api/admin/users/:id
POST   /api/admin/users/:id/role            # {"role": "admin"|"user"}
POST   /api/admin/users/:id/sandbox-limit   # {"limit": n}
POST   /api/admin/users/:id/comp            # {"comped": true|false}
POST   /api/admin/users/:id/suspend         # {"suspended": true|false}
POST   /api/admin/users/:id/credits         # {"cents": n, "note": "..."}: grant credit
DELETE /api/admin/users/:id
GET    /api/admin/sandboxes
POST   /api/admin/sandboxes/:id/reap
GET    /api/admin/audit                     # cross-tenant audit events
GET    /api/admin/events                    # the privilege trail: who did what to whom
```

Here are the refusals. You cannot suspend your own account, delete it, or
change its role. Use another admin, or `DELETE /api/account` to delete your
own.

The payment actions are `404` with `"billing": "disabled"` on an instance
with payment off. Those actions are comp and credits.

A read across tenants returns metadata alone. Prompt content and output
content never cross a tenant boundary, whatever the role.

## Webhooks

```
GET    /api/webhooks                                  # list endpoints
POST   /api/webhooks                                  # create one; the secret is in this response only
GET    /api/webhooks/:id
PATCH  /api/webhooks/:id                              # url, description, event_types, status
DELETE /api/webhooks/:id
POST   /api/webhooks/:id/rotate-secret                # a new secret; the old one stops verifying
POST   /api/webhooks/:id/test                         # queue a signed `webhook.test` event
GET    /api/webhooks/:id/deliveries                   # ?limit= (default 50, max 200)
POST   /api/webhooks/:id/deliveries/:delivery_id/redeliver
```

Fountain sends conversation lifecycle transitions to a URL you own. An
integration that cannot hold a socket open does not have to poll. The payload
carries ids, a stage and a duration, and never conversation content.

These routes need a full-scope key. A sandbox's per-conversation token must
not point the account's events at a URL that the sandbox picks.

The [webhooks reference](reference/webhooks.md) holds the full event
catalogue, the payload shape, a worked signature verifier and the
at-least-once contract.

## Audit

```
GET    /api/audit    # ?limit= ?before= ?action_prefix= ?resource_type= ?since= ?until=
```

This is the account's own append-only trail, newest first. Each row carries
`id`, `inserted_at`, `actor`, `action`, `resource_type`, `resource_id`,
`metadata` and `request_ip`.

`actor` tells four things apart. `ui` is a browser session. `api` is a bearer
key. `sprite` is the token a sandbox holds for one conversation. `system` is
Fountain itself.

To page backwards, pass `meta.next_cursor` as `before`. `limit` defaults to
100, and caps at 500.

`action_prefix` matches a family of actions, such as `vault.`. Fountain treats
it as a literal, and not as a LIKE pattern.

`since` and `until` take ISO 8601 timestamps. Fountain refuses a malformed one
with a `400`, and ignores none of them without a sound.

You see this tenant's events, and no other tenant's.

The `/audit` page in the browser takes the same four filters, as `?action=`,
`?resource=`, `?since=` and `?until=`. It runs them through the same query, so
a filtered view is a link you can share.

That page shows the newest 200 matches, and it has no pages. Use this endpoint
to walk the whole trail.

## Error responses

```json
{"error": "not_found", "message": "Agent not found"}
```

| Status | Meaning |
|---|---|
| `400` | The request body is invalid. |
| `401` | The auth is absent or invalid. |
| `402` | Your credit balance is zero or below. The code is `insufficient_credits`, and the body carries `upgrade_url`. The old `subscription_required` code does not occur. A teammate contact past the account's ceiling is `contact_limit_reached`. |
| `403` | The wrong tenant. |
| `404` | Nothing found. |
| `409` | The request conflicts with the current state. The codes are `no_runner_online`, `sandbox_at_capacity`, `sandbox_not_attachable`, `sandbox_mid_turn`, `permission_request_resolved` and `contact_already_provisioned`. |
| `410` | Somebody terminated the conversation. The code is `conversation_terminated`. Stop, and do not try again. |
| `422` | A validation error. |
| `429` | The rate limit stopped you. |
| `500` | An internal error. |
| `503` | The instance is at its fleet ceiling, or a sandbox is not up yet. The codes are `fleet_full`, `provisioning` and `sprite_probe_failed`, and the response carries `Retry-After`. |

## LLM-native discovery

- `/llms.txt`, a short API summary.
- `/llms-full.txt`, the full API reference.
- `/skill`, a drop-in skill for Claude Code, Cursor, Continue and Aider.

Read [LLM integration](llm-integration.md) for the detail.
