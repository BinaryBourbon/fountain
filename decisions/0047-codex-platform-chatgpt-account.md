---
type: ADR
title: "Run the codex runtime on the platform's ChatGPT account"
description: "An admin signs the Fountain server in to ChatGPT once; the server keeps the rotating refresh token, the broker carries the access token to chatgpt.com, and a codex sandbox holds only a placeholder. Nothing here is built and none of the five G0 measurements has been taken."
tags: [inference, broker, codex, security, billing]
status: draft
adr: "0047"
adr_status: "Proposed"
date: 2026-09-08
generated: { by: claude-fable/5.1, at: 2026-09-08T12:00:00-04:00 }
stale_after: 2026-10-08
---

# 0047 — Run the codex runtime on the platform's ChatGPT account

**Status:** Proposed, 2026-09-08. **Nothing described here is built, and
none of the measurements in [Measured](#measured) has been taken.** Every
mechanism below is a plan until its gate lands; the gate that builds it
removes its caveat here in the same PR. The PR that lands G0 fills the
Measured block and, if measurement 2 fails, marks this ADR Superseded rather
than proceeding to G1.

Amends [0038](0038-onboarding-first-reply.md) decision 3 (platform inference
keys) with a second kind of platform credential, and
[0019](0019-egress-credential-brokerage.md) gate 3 (brokered inference
credentials) with a fifth `@inference` entry. Scope is the `codex` runtime
only. Opencode against an `openai/...` model keeps needing an API key.

## Context

### What we want

An admin signs the Fountain **server** in to ChatGPT once. Fountain keeps the
refresh token and owns its lifecycle. The egress broker carries the access
token to `chatgpt.com`. A sandbox running the `codex` runtime holds only a
placeholder. A tenant with no OpenAI credential of their own can then run a
codex agent on the deployment's subscription, metered like any other platform
inference (0038 decision 3).

### Why the Claude pattern does not transfer

The Claude OAuth credential is a long-lived static string from
`claude setup-token`, so gate 3 of 0019 exports it into every sandbox as a
placeholder and the broker substitutes it on `api.anthropic.com`. ChatGPT
has no such string:

- Codex's ChatGPT login is OAuth with a **rotating, single-use refresh
  token**. The auth server returns `refresh_token_reused` as a terminal
  error. OpenAI's CI guidance says one `auth.json` per runner, never shared
  across concurrent jobs. openai/codex#15502 and #15410 report the copy flow
  breaking for exactly this reason; #15410 was closed as not planned.
- Fountain runs many sandboxes per tenant concurrently, and several
  conversations share one sandbox (0023). The first one to refresh would
  kill every other copy.

So the refresh token must live in exactly one place, the server, and a
sandbox must receive something that never needs refreshing from inside.

### What Codex does with a ChatGPT login

Read from `openai/codex` `main` on 2026-09-08. Re-verify against the version
the sandbox images install (`codex --version` inside a sandbox; the review
image had 0.147.0 and production sandboxes ran 0.153.3 on 2026-09-06).

| Fact | Where |
|---|---|
| `auth.json` lives at `$CODEX_HOME/auth.json`, default `~/.codex`. In a Fountain sandbox that is `/home/sprite/.codex/auth.json` (`Managoat.Runtimes.Layout`). | docs, `layout.ex` |
| Three modes: `apiKey`; `chatgpt`, where codex owns the refresh token; and `chatgptAuthTokens`, "externally managed tokens": access token only, `refresh_token: ""`, codex never refreshes and never checks `exp`. `chatgptAuthTokens` loads from disk. | `codex-rs/login/src/auth/manager.rs` ~line 398 |
| JWT payloads are base64-decoded and never signature-checked. `id_token` must be three non-empty dot-separated segments; codex reads `email`, and under the `https://api.openai.com/auth` claim `chatgpt_account_id`, `chatgpt_user_id`, `chatgpt_plan_type`. The access token is parsed only in `get_chatgpt_account_user_id`, which swallows errors. | `codex-rs/login/src/token_data.rs` |
| Refresh is `POST https://auth.openai.com/oauth/token` with JSON `{client_id, grant_type: "refresh_token", refresh_token}`. Client id `app_EMoamEEZ73f0CkXaXp7hrann`. Terminal codes: `refresh_token_expired`, `refresh_token_reused`, `refresh_token_invalidated`; a 400 `invalid_grant` is also terminal. | `manager.rs` `request_chatgpt_token_refresh` |
| In `chatgpt` mode codex refreshes 5 minutes before the access token's `exp`, or when `last_refresh` is older than 8 days. Treat 8 days as the idle limit of the grant until measured. | `manager.rs` consts |
| Device flow on `https://auth.openai.com`: `POST /api/accounts/deviceauth/usercode` `{client_id}` returns `{user_code, device_auth_id, interval}`; the user approves at `/codex/device`; poll `POST /api/accounts/deviceauth/token` `{device_auth_id, user_code}` until 200 (403/404 mean not yet, 15 minutes max), which returns `{authorization_code, code_verifier, code_challenge}`; exchange at `/oauth/token` with `redirect_uri = https://auth.openai.com/deviceauth/callback`. The account must have device-code login enabled in ChatGPT security settings. | `codex-rs/login/src/device_code_auth.rs` |
| With any ChatGPT auth mode the **built-in** `openai` provider's base URL is `https://chatgpt.com/backend-api/codex`. Requests carry `Authorization: Bearer <access>` and `chatgpt-account-id: <account_id>`. | `codex-rs/model-provider-info/src/lib.rs` |
| A provider with `env_key` gets a bare bearer from that env var, **no** account id and **no** `auth.json`. A provider with `requires_openai_auth: true` and no `env_key` gets the ambient `auth.json` auth (bearer plus account id), whatever its id. | `codex-rs/model-provider/src/auth.rs` `resolve_provider_auth` |
| Only the built-in id satisfies `supports_codex_backend_routes` (guardian endpoint, remote compaction, token budget). A non-openai provider also strips encrypted function-call args and internal chat metadata from the request (`client.rs` `build_responses_request`). | `codex-rs/core/src/client.rs` |
| Enterprise "access tokens" (`CODEX_ACCESS_TOKEN`, `codex login --with-access-token`) are static, non-refreshing, and minted in the admin console for Business and Enterprise workspaces only. | docs `enterprise/access-tokens` |

### What Fountain already has

Each of these is reused, not reinvented. Module and function names were
checked against `main` at `59c5ebc8` on 2026-09-08.

- **Tenant credentials.** `Fountain.InferenceCredentials.Credential` holds
  four atoms (`anthropic_api_key`, `claude_code_oauth_token`,
  `openai_api_key`, `gemini_api_key`). `credentials_for_provider/1` and
  `select/2` decide which credential a model runs on; the tenant's own
  always wins.
- **Platform keys** (0038 decision 3, #1388, #1728).
  `Fountain.PlatformInference.key_for/1` reads a `platform_inference_keys`
  row (`PlatformInference.Key`, encrypted with
  `Fountain.Crypto.encrypt_platform/1`) before the
  `PLATFORM_<PROVIDER>_API_KEY` variable. The admin page is
  `FountainWeb.AdminLive.Inference` at `/admin/inference`; the audit events
  are `admin.platform_inference_key.set` and `.cleared` in
  `Fountain.Audit.AdminEvent`.
- **The broker** (0019, on for every tenant since 2026-09-04).
  `Fountain.Broker`'s `@inference` table maps an env var to a credential
  atom and its hosts; `split_inference/2` swaps the value for
  `placeholder/1` (`__lowercase_key__`, vendor-prefixed via
  `@inference_prefix`) and gives the broker an implicit `substitute` binding
  to those hosts. The proxy's unmatched-host policy is `deny`, so the binding
  is also what lets the host through. 0019 decision 4 makes the placeholder
  name a contract between Fountain and the broker.
- **Server-owned refresh tokens.** `Fountain.Connections.access_token/1`
  refreshes 300 s ahead of expiry under a per-row advisory lock (namespace
  4331), marks the row `revoked` on `invalid_grant` and `expired` when there
  is no refresh token. That is the lifecycle this credential needs, already
  written for Gmail.
- **Per-turn refresh** (#1736).
  `Fountain.Conversations.Egress.refresh_before_turn/1` re-reads every
  brokered source before each turn and, when something changed,
  `Broker.refresh/4` rewrites `rules_ciphertext` on every live session row
  behind the token the sandbox already holds. `Broker.prepare/4` is an
  INSERT that an idle ACP peer never sees. New brokered sources go into
  `reread_secrets/1`.
- **Codex provisioning.** `Managoat.Runtimes.Codex.prepare_sandbox/3` in the
  hex library `managoat_runtimes` (pinned `~> 0.3.2` in
  `apps/fountain/mix.exs`) pipes `OPENAI_API_KEY` into
  `codex login --with-api-key`, because codex 0.118+ reads only
  `~/.codex/auth.json`. Changing it is a library release and a pin bump: two
  PRs in two repositories.
- **Codex transport** (#1674). `Fountain.Conversations.CodexTransport`
  rewrites the spawn's `CODEX_CONFIG` to declare and select
  `fountain_openai_http` (`supports_websockets: false`,
  `env_key: "OPENAI_API_KEY"`) because codex's websocket dialer rejects an
  https-scheme proxy and burns the connect timeout first (about 300 s per
  turn, measured). The built-in `openai` id cannot be overridden. This is
  the seam for the new provider shape.

## Decision

The whole design is where each secret lives. Only one thing changes hands at
each hop, and the secret the subscription depends on, the refresh token,
never leaves the server.

```
Admin ──device code / paste──▶ Fountain server ──access token──▶ Broker ──substituted bearer──▶ chatgpt.com
                               (refresh token,                  (substitute rule,
                                encrypted, refreshed             host chatgpt.com)
                                ahead of exp + keepalive)              ▲
                                                                       │ Authorization: Bearer __codex_chatgpt_access_token__
                                                                       │ chatgpt-account-id: <real id>
                                                             Sandbox: ~/.codex/auth.json (chatgptAuthTokens)
```

### 1. The deployment holds one ChatGPT grant, beside its platform API keys

A new table `platform_chatgpt_account`, one row, schema
`Fountain.PlatformChatGPT.Account`: `refresh_token_ciphertext`,
`access_token_ciphertext`, `id_claims` (jsonb, the decoded non-secret
claims), `account_id`, `account_email`, `plan_type`, `access_expires_at`,
`last_refreshed_at`, `status` (`active` | `revoked` | `expired`),
`revoked_reason`, `updated_by_user_id` (nilified on delete, like
`platform_inference_keys`), timestamps. Ciphertexts go through
`Crypto.encrypt_platform/1`. The row gets a nullable `user_id` from day one
so a per-tenant "connect your ChatGPT" is the same row with an owner rather
than a second table, but that surface is not built here.

### 2. The admin connects from `/admin/inference`, by paste first and by device code second

A "ChatGPT account" row joins the three provider rows, with states
*not connected* / *connected as `<email>`* (`<plan>`, last renewed, next
expiry) / *revoked (`<reason>`)* / *expired*, plus Paste and Disconnect.
Paste accepts the file `CODEX_HOME=$(mktemp -d) codex login` writes on a
laptop, which is OpenAI's own CI recipe, validated as `auth_mode: "chatgpt"`
with a non-empty refresh token. Device-code Connect (G3) runs the flow from
the server in a supervised task, shows URL and code in a modal, and polls at
the returned interval. Either way the admin is told plainly: this login is
now Fountain's, and using that same `auth.json` anywhere else will break both.

### 3. Fountain owns the refresh token and is the only thing that ever uses it

`Fountain.PlatformChatGPT.access_token/0` mirrors
`Connections.access_token/1`: refresh when within the margin of `exp`,
serialized under an advisory lock (a second concurrent refresh is a dead
grant), and the rotated refresh token is persisted **before** the new access
token is handed out. The margin must exceed the longest turn the deployment
expects, because codex cannot recover a 401 in this mode (decision 5); it
starts at 15 minutes and is config. A keepalive worker
(`Fountain.Workers.PlatformChatGPTKeepalive`, an Oban cron job like
`SecretExpirySweeper`) refreshes when `last_refreshed_at` is older than
6 days so the grant never idles past the 8-day window while nobody runs
codex. A terminal refresh error marks the row `revoked` with the server's
reason code; codex conversations then fall through to the platform
`OPENAI_API_KEY` if one is set, else `{:error, :no_credential}`.

### 4. The sandbox gets `auth.json` in `chatgptAuthTokens` mode, with a placeholder where the bearer goes

A fifth credential atom, `:codex_chatgpt_access_token`, travels in the same
map as the others. `Fountain.Broker`'s `@inference` table gains
`"CODEX_CHATGPT_ACCESS_TOKEN" => %{cred: :codex_chatgpt_access_token, hosts: ["chatgpt.com"]}`,
so `split_inference/2` brokers it exactly like the Claude OAuth token.
`Managoat.Runtimes.Codex.default_env/2` exports
`CODEX_CHATGPT_ACCESS_TOKEN` and the account id, and `prepare_sandbox/3`
gains a branch: when that env var is present, write the file below instead
of running `codex login --with-api-key`. The `id_token` is synthesised by
Fountain from the stored claims with an empty signature segment, so the
admin's real identity token and email never enter the sandbox. This
credential is offered to brokered tenants only; a self-hosted runner refuses
brokering, so a runner conversation on the codex runtime sees no ChatGPT
credential and takes the API-key path.

```json
{
  "auth_mode": "chatgptAuthTokens",
  "tokens": {
    "id_token": "eyJhbGciOiJub25lIn0.<claims: chatgpt_account_id, chatgpt_user_id, chatgpt_plan_type>.x",
    "access_token": "__codex_chatgpt_access_token__",
    "refresh_token": "",
    "account_id": "<real account id>"
  },
  "last_refresh": "<now, ISO 8601>"
}
```

**Transport.** `CodexTransport` keeps its provider swap and gains a second
shape. When the spawn env carries `CODEX_CHATGPT_ACCESS_TOKEN` and no
`OPENAI_API_KEY`, the declared provider is the one below. Codex then
resolves the ambient auth from `auth.json`, sends the placeholder as the
bearer with the real `chatgpt-account-id`, and never opens the websocket
that stalls behind the broker. What it gives up is the built-in-only
routes (guardian endpoint, remote compaction, token budget), none of which
a Fountain turn depends on. The `OPENAI_BASE_URL` rule for the API-key
shape is untouched.

```json
{
  "model_provider": "fountain_openai_http",
  "model_providers": {
    "fountain_openai_http": {
      "name": "OpenAI",
      "base_url": "https://chatgpt.com/backend-api/codex",
      "wire_api": "responses",
      "requires_openai_auth": true,
      "supports_websockets": false
    }
  },
  "features": { "respect_system_proxy": true }
}
```

### 5. Rotation reaches a running conversation through the broker, never through the sandbox

`Egress.refresh_before_turn/1` gains one more source in `reread_secrets/1`:
read `PlatformChatGPT.access_token/0`, swap it into
`brokered["CODEX_CHATGPT_ACCESS_TOKEN"]`, and let the existing
changed-then-rewrite path through `Broker.refresh/4` carry it. The sandbox
file never changes, the session token never changes, and an idle codex-acp
peer picks up the new bearer on its next request without a spawn. A turn
that outlives the token fails at the proxy with a 401 from `chatgpt.com` on
the transcript, the same failure shape a lapsed Connection has today.

### 6. Selection: tenant credential first, then the subscription for codex, then the platform API key

`InferenceCredentials.select/2` keeps its rule that a tenant's own key
always wins. For provider `openai` with no tenant credential, it takes the
ChatGPT grant when the agent's runtime is `codex` and the grant is `active`,
else the platform `OPENAI_API_KEY`. `select/2` currently takes only
`(model, own_creds)`; the runtime is threaded in from its one caller. The
origin stays `:platform`, so the ledger prices the turn and the daily
ceiling counts it (0038 decision 3). The ceiling measures turn-hours, not
the subscription's own five-hour and weekly windows; those are shared by
every tenant on the grant, and when they trip codex reports it on the
transcript. No automatic fallback within a turn.

### 7. Audit records the grant's life, never a token

`admin.platform_chatgpt.connected` (method, account id, email, plan),
`admin.platform_chatgpt.disconnected`, and actor `system:platform_chatgpt`
for `revoked` and `expired` with the server's reason code. Routine
refreshes are not audited, the same as Connections. Never a token, never a
claim that is a secret, never inside a transaction (0013).

### 8. The same slot accepts a workspace access token, and it is the preferred one

A deployment on ChatGPT Business or Enterprise pastes a `CODEX_ACCESS_TOKEN`
instead. It is stored in the same row with no refresh token, `status`
flips to `expired` on its admin-set expiry, and the sandbox and broker path
is identical. This is OpenAI's sanctioned non-interactive credential, and
where it is available it is the one to use.

## Lifecycle

| Event | What Fountain does | What the admin sees |
|---|---|---|
| Connect | Paste or device flow. Stores tokens, decodes claims, records `connected`. | "Connected as jake@… (Pro). Token renews automatically." |
| Conversation start | `select/2` picks the grant, `access_token/0` refreshes if within margin, broker gets the value, sandbox gets the placeholder file. | Nothing. |
| Before each turn | `refresh_before_turn/1` re-reads the access token and rewrites the live session's rules if it rotated. | Nothing. |
| Idle week | Keepalive worker refreshes so the grant does not lapse. | "Last renewed 3 days ago." |
| Refresh refused | Row marked `revoked` with the reason code; codex falls through to the platform API key or `:no_credential`. | "Sign-in lost: refresh token was already used. Reconnect." with a Connect button. |
| Subscription rate limit | Nothing server-side; codex reports the reset time on the transcript. | Optional later: the usage window from codex's rate-limit response. |
| Disconnect | Deletes the row, records `disconnected`. Running conversations keep their session until the next turn's re-read. | Row returns to "Not connected". |

## Measured

**As of 2026-09-08 none of these has been run.** They are laptop and
dev-broker experiments, not builds, and each one decides something above.
The G0 PR replaces every "not yet measured" below with a dated result, and
if measurement 2 fails this ADR stops at G0. Use a throwaway `CODEX_HOME`
and a personal ChatGPT account, never `~/.codex`.

| # | Measurement | Decides | Result |
|---|---|---|---|
| 1 | **Access token lifetime.** `CODEX_HOME=$(mktemp -d) codex login`, decode the middle segment of `tokens.access_token`, report `exp - iat`. | The refresh margin in decision 3; a lifetime shorter than a long turn changes decision 5. | not yet measured |
| 2 | **Placeholder end to end, on the custom provider.** In a dev checkout with `BROKER_LISTEN_PORT` set, hand-write the `chatgptAuthTokens` file into a dev sandbox, add a manual `substitute` binding for `CODEX_CHATGPT_ACCESS_TOKEN` to host `chatgpt.com` with the real access token, set the `CODEX_CONFIG` from decision 4, run a turn that makes a tool call. Done when the reply arrives and `broker_requests` shows `chatgpt.com` with outcome `:injected`. | Whether decision 4 is viable at all. If codex rejects the placeholder shape, try a JWT-shaped placeholder via `@inference_prefix`. If the backend rejects the non-openai request shape, stop: the fallback (built-in provider over codex's explicit proxy route, upstream #13103) is a different piece of work. | not yet measured |
| 3 | **Rotation.** Refresh with `curl` against `/oauth/token`, confirm the old refresh token is refused with `refresh_token_reused`, confirm the new access token works through the broker with the sandbox file unchanged. | Decision 5's claim that the sandbox file never changes. | not yet measured |
| 4 | **Device flow from a non-CLI caller.** Run the three calls from `iex` with `Req` and the Codex client id. | Whether G3's Connect is possible; if the server keys on something the CLI sends, paste is the only Connect. | not yet measured |
| 5 | **Idle lifetime.** Leave a second grant untouched and refresh on day 9 (and day 30). | The keepalive interval in decision 3. | not yet measured; start it at G0, report later |

## Consequences

- **A tenant with no OpenAI key can run codex on the hosted deployment**,
  and the turn is priced at `:platform` like any other platform inference.
  The subscription's own rate windows are shared across every tenant on the
  grant and are not something Fountain can meter.
- **A second credential lifecycle joins the platform surface.** Platform
  API keys are static; this one rotates, idles out and can be revoked from
  the far side. The admin page, the audit trail and the docs all gain a
  stateful row, and `system:platform_chatgpt` joins the closed actor
  vocabulary in 0013.
- **The `@inference` contract (0019 decision 4) grows by one entry**, and the
  managoat_runtimes library learns a second way to provision codex. Both
  sides ship separately, so the pin bump is the point at which the two
  agree.
- **Codex gives up its built-in-only routes** on this path: guardian
  endpoint, remote compaction, token budget, and the encrypted function-call
  args a non-openai provider strips. Measurement 2 is what tells us whether
  the backend still accepts the request.
- **Terms and risk.** OpenAI's docs position ChatGPT sign-in for the Codex
  client and route programmatic use to API keys and workspace access
  tokens. This design runs the real `codex` binary against its own
  `auth.json`, which is the sanctioned client, and it does not call
  `backend-api` from the server the way the opencode plugins do. It does put
  many tenants on one consumer subscription, which is the pattern behind
  the reported account bans, and it uses the Codex OAuth client id from a
  server that is not Codex. Anthropic banned the equivalent for Claude
  consumer plans in April 2026. Treat that as the likely direction: the
  workspace access token (decision 8) is the first-class path, and the
  personal-subscription path is an operator option with this caveat written
  down in `docs/configuration.md`, not a product feature.

## Build order

One PR per gate, each green on `CI required`, each with its done-when
evidence in the description.

| Gate | Builds | Done when |
|---|---|---|
| **G0** | The five measurements above, in a throwaway `CODEX_HOME` and a dev broker. Fills the Measured block. | A codex turn completes with the placeholder in the sandbox and the bearer only at the proxy, and the lifetimes are written into this record. |
| **G1** | Migration and schema, `Fountain.PlatformChatGPT` (`connect_from_auth_json/2`, `access_token/0`, `disconnect/1`, `status/0`), the keepalive worker, the paste-to-connect row on `/admin/inference`, the audit events, a section in `docs/configuration.md`. | A pasted grant survives a forced refresh and the keepalive, `admin_inference_live_test.exs` covers all four row states, and a deliberately reused refresh token flips the row to `revoked` with `refresh_token_reused`. |
| **G2** | The `@inference` entry, the runtime-aware `select/2`, the extra source in `reread_secrets/1`, the second provider shape in `CodexTransport`, and the `default_env/2` + `prepare_sandbox/3` branch in managoat_runtimes (library release, pin bump). | A tenant with no OpenAI key runs a codex agent on the grant in a real sandbox, the transcript shows a reply to a tool-calling prompt, the egress log shows only `chatgpt.com` injected for that conversation, and the ledger row for the turn says `:platform`. |
| **G3** | Device-code Connect in a supervised task (`Task.Supervisor.start_child(Fountain.TaskSupervisor, ...)`, never `Task.async`), workspace-token paste (decision 8), revocation UX on the row. | An admin connects with no laptop-side codex install. |

## Alternatives considered

- **Copy `auth.json` into each sandbox, like the Claude token.** The refresh
  token rotates and is single-use, so the first sandbox to refresh kills
  every other copy. OpenAI says so and the issue tracker confirms it.
- **Let codex refresh inside the sandbox and read the rotated token back.**
  Concurrent sandboxes race on one grant, and the sandbox would hold the
  refresh token, which is the one secret worth stealing.
- **Call `chatgpt.com/backend-api` from the server and expose an
  OpenAI-compatible endpoint (0035).** Reverse-engineered, not the Codex
  client, and the clearest terms violation of the options.
- **Per-tenant ChatGPT connections instead of a platform grant.** The same
  row with an owner, and where this should go if consumer subscriptions
  turn out to be allowed. The platform grant is the smallest version and
  the one the hosted deployment needs first; decision 1's nullable `user_id`
  keeps the door open.
- **Wait for OpenAI to publish a static token for consumer plans.** Nothing
  suggests one is coming; workspace access tokens are the answer they
  shipped, for Business and Enterprise.
- **The built-in `openai` provider over codex's explicit proxy route.**
  Opt-in in 0.153 and the subject of upstream #13103. It keeps the
  built-in-only routes but reintroduces the websocket stall #1674 removed.
  It is the fallback if measurement 2 fails, not the first choice.

## Sources

- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Maintain Codex account auth in CI/CD](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
- [Codex access tokens (Business/Enterprise)](https://learn.chatgpt.com/docs/enterprise/access-tokens)
- [codex-rs/login/src/auth/manager.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs)
- [codex-rs/login/src/token_data.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/token_data.rs)
- [codex-rs/login/src/device_code_auth.rs](https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs)
- [codex-rs/model-provider-info/src/lib.rs](https://github.com/openai/codex/blob/main/codex-rs/model-provider-info/src/lib.rs)
- [openai/codex #15502](https://github.com/openai/codex/issues/15502),
  [#15410](https://github.com/openai/codex/issues/15410),
  [#13103](https://github.com/openai/codex/issues/13103)
- [7shi/codex-oauth](https://github.com/7shi/codex-oauth),
  [mostlyuseful/codex-access-token](https://github.com/mostlyuseful/codex-access-token),
  [codex-lb OAuth configuration](https://mintlify.wiki/Soju06/codex-lb/configuration/oauth)
- [Anthropic bans subscription auth in third-party tools](https://alternativeto.net/news/2026/2/anthropic-officially-bans-using-subscription-authentication-for-third-party-claude-use)
- [ChatGPT and Codex account ban risk guide](https://blog.4sapi.com/blog/chatgpt-codex-account-ban-api-guide)
