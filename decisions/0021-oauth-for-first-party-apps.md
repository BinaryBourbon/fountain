---
type: ADR
title: "Fountain is the OAuth 2.0 authorization server for its own browser apps (code + PKCE, public clients, keys as tokens)"
description: "The standalone team and conversations apps on other origins sign in with a Fountain session instead of a pasted API key: authorization code + PKCE (S256), public clients registered in config, redirect URIs exact, tokens are ordinary expiring API keys. No client secrets, no refresh tokens yet, no third-party clients yet."
tags: [auth, oauth, api, spa]
status: stable
adr: "0021"
adr_status: "Accepted"
date: 2026-08-18
generated: { by: human:jhgaylor, at: 2026-08-18T14:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-18T14:00:00-04:00 }
stale_after: 2026-11-18
---

# 0021 — Fountain is the OAuth 2.0 authorization server for its own browser apps

**Status:** Accepted — built in [#819](https://github.com/BinaryBourbon/fountain/pull/819):
`Fountain.OAuth`, `GET/POST /oauth/authorize`, `POST /api/oauth/token`,
`POST /api/oauth/revoke`, `OAUTH_CLIENTS`.

## Context

Two of Fountain's user surfaces now live outside the Phoenix app, on another
origin: the team app (fountain#810) and the conversations app (fountain#813,
#815), static sites talking only to `/api` over CORS with a bearer API key.
Until now the key had to be created under Account → API keys and pasted in.
That is fine for a CLI and wrong for an app: it teaches people to copy
long-lived secrets around, and it makes the first minute of the app a
scavenger hunt.

Fountain already has the two things a proper answer needs: a browser session
(email/password or GitHub via Ueberauth) and API keys with scopes, expiry
and revocation, checked by `TenantAPIAuth`. What was missing was the bridge
from one to the other with the user's consent.

## Decision

Fountain acts as the **OAuth 2.0 authorization server** for its own apps.

- **Grant:** authorization code with **PKCE, S256 only**, for **public
  clients** — what a browser app can do safely. No client secret exists; the
  code, the verifier and the exact `redirect_uri` are the whole proof.
- **Client registry in config**, not a table: `config :fountain,
  :oauth_clients` (runtime.exs reads `OAUTH_CLIENTS` as JSON) lists
  `{id, name, redirect_uris}`. Redirect URIs match **exactly**. Two clients
  are ours; a table and an admin UI come when a third party asks.
- **Consent page** at `GET /oauth/authorize` behind the browser session:
  names the client, Allow / Deny. Signed out → the request is stashed
  (`FountainWeb.ReturnTo`) and the normal login — password or GitHub —
  returns to it. A request whose client or redirect does not check out is
  **rendered** as an error, never redirected: a redirect to an unregistered
  URI is exactly the open redirector the allowlist prevents.
- **Codes** are hashed at rest, bound to user + client + redirect_uri +
  challenge, live 5 minutes, and are single-use by a conditional update.
- **Tokens are API keys.** A successful exchange mints an ordinary key
  (`Accounts.create_api_key/3`) named `oauth:<client_id>`, full scope,
  expiring in 30 days. So it lists and revokes under Account → API keys,
  `TenantAPIAuth` and the audit trail need no change, and revoke on sign-out
  is `POST /api/oauth/revoke` with the token itself. `oauth.authorized` is
  recorded at consent; `api_key.created` at exchange.
- **One error for every wrong grant** at the token endpoint (`invalid_grant`),
  rate-limited per IP; the response never says which check failed.
- **No refresh tokens (yet).** 30-day keys and a fresh sign-in when they
  expire is enough for first-party apps; refresh rotation is a follow-up if
  the expiry annoys.

## Consequences

- The apps get "Sign in with Fountain" with ~80 lines of PKCE and a callback
  route; the paste-a-key path stays as the fallback and for the CLI
  (`POST /api/auth/token` is untouched).
- Every login method Fountain has now, or grows later, works for the apps for
  free — the OAuth layer sits on the session, not on a provider.
- Adding an app = one entry in `OAUTH_CLIENTS` (and `API_CORS_ORIGINS`).
- What this is **not**: a way for third parties to act as Fountain users. The
  registry is ours, consent is coarse (full scope), and there are no scopes
  narrower than what API keys already have. Doing that properly means a
  clients table, per-scope consent and refresh rotation — the shape is
  compatible, the work is not done.
