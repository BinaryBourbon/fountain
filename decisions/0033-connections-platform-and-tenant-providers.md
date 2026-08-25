---
type: ADR
title: "Connections: one platform provider, tenant-defined providers for everything else, and MCP-spec discovery for remote servers"
description: "Built. A connection is a provider account Fountain holds the credential for and hands to an agent as a capability, never as a token in the sandbox. Google is the one provider with a Fountain-owned OAuth client; every other service is a provider the tenant defines from their own app registration, and a remote MCP server is a provider Fountain discovers (RFC 9728 / 8414) and registers a client with (RFC 7591). Only for accounts the egress broker is on for."
tags: [security, secrets, connections, oauth, mcp, egress]
status: stable
adr: "0033"
adr_status: "Accepted"
date: 2026-08-25
generated: { by: human:jhgaylor, at: 2026-08-25T21:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-25T21:00:00-04:00 }
---

# 0033 — Connections: one platform provider, tenant-defined providers for everything else, and MCP-spec discovery for remote servers

**Status:** Accepted, built in #1182 (Google, #1178) and the PR that adds this
file (#1186). Nothing described here is unbuilt.

## Context

An agent that reads a mailbox, files an issue or calls a SaaS API needs a
credential for it. Before #1178 the only way to give it one was to put the
token in an environment or a vault, from where it reached the sandbox in the
clear — and any agent that prints its environment has leaked it. ADR 0019
moved the *inference* keys and the tenant's own secrets behind the egress
broker; the OAuth'd services were still the tenant's problem: obtain a token
somewhere, paste it, refresh it by hand when it lapsed.

#1178 built **connections**: the tenant signs in to Google once in the
console, Fountain runs the authorization-code flow and keeps the refresh
token DEK-encrypted like a vault secret, and the agent gets a capability —
a Fountain-served Gmail MCP server, or an access token brokered to Google's
hosts under `GOOGLE_ACCESS_TOKEN` — rather than a credential. That is the
shape managed-agent platforms use for connectors, and it worked on day one.

It also raised the question this ADR answers: **whose OAuth client is it,
and how does a tenant connect a service Fountain has no client for?** The
end goal named in #1178 was a *tenant-supplied* OAuth'd MCP server — a
Linear, a Notion, a server of their own — and a platform that owns an OAuth
app at every service does not scale, for three reasons that do not go away
with effort:

1. Registering an app is per service, per platform account, and often per
   verification review. Google's restricted scopes take weeks of review per
   app; GitHub's fine-grained apps need an installation flow; Slack's need a
   published manifest. Fountain cannot carry that for the long tail.
2. The tenant's compliance story is about *their* app: an auditor asks which
   application holds the grant to their Notion workspace, and the honest
   answer should name an app the tenant registered and can revoke at the
   service, not one Fountain owns on their behalf.
3. Remote MCP servers already solved this for themselves. The MCP
   authorization specification says a server answers an unauthenticated
   request with `401` and `WWW-Authenticate: Bearer resource_metadata=…`,
   publishes RFC 9728 protected-resource metadata naming its authorization
   server, whose RFC 8414 metadata names the endpoints, and — where the
   server is friendly — offers RFC 7591 dynamic client registration so a
   client needs no pre-arranged id at all. A platform that ignored this
   would be asking the tenant to type what the server already publishes.

## Decision

1. **Google is the one platform provider.** It keeps Fountain's own OAuth
   client (`GOOGLE_OAUTH_CLIENT_ID` / `_SECRET`), the Fountain-served Gmail
   MCP server, and `access_type=offline` + `prompt=consent` on every
   authorize URL. It is a `Fountain.Connections.Provider` struct built from
   config (`Provider.google/0`), `user_id: nil`, id `"google"`, with no row.
   No second platform provider is planned; adding one would need this ADR
   amended with the reason the tenant's own app cannot do the job.

2. **Every other service is a provider the tenant defines.** A
   `connection_providers` row, tenant-scoped, of two kinds:
   - `oauth2`: the tenant registered an app at the service and gives
     Fountain the authorize / token / revoke / userinfo URLs, the scopes,
     the client id and secret (DEK-encrypted), the token-endpoint auth
     method (`client_secret_post` | `client_secret_basic` | `none`), whether
     PKCE is on, the env var the token is brokered under, and the hosts the
     broker attaches it to. The console offers presets (GitHub, Slack,
     Notion, Linear) that fill the endpoints; the tenant pastes only the
     client id and secret.
   - `mcp`: the tenant enters the server's URL and nothing else.
     `Fountain.Connections.McpDiscovery` follows the chain above, and
     registers a client where there is a `registration_endpoint`. The
     registered client is stored on the provider and reused for another
     server behind the same issuer (RFC 7591 clients are per authorization
     server, not per resource). A server without registration is saved
     without a client, and the console asks the tenant to paste one.
   Both kinds are driven by one OAuth client, `Fountain.Connections.OAuth`,
   which reads everything that differs per provider from the row: PKCE
   (S256; always for `mcp`, which also sends the RFC 8707 `resource`
   parameter), the client-auth method, and the account-label strategy
   (`userinfo_url` + a JSON path, or a label the tenant types at connect).

3. **The redirect URI is per provider**:
   `<PUBLIC_URL>/connections/<provider id>/callback`, alongside the platform
   `/connections/google/callback`. The console shows it to paste into the
   app registration. The `state` parameter is a signed token over the user
   id and a session nonce; the PKCE verifier rides in the same session entry
   and is spent on the callback. A callback for a different provider than
   the one that started, or from a different session, is refused.

4. **Refresh follows the provider's behaviour, not Google's.** A refresh
   response that carries a new refresh token rotates the stored one. No
   `expires_in` means the access token does not expire until the provider
   refuses it. No refresh token at all (GitHub OAuth apps, some MCP servers)
   means the connection goes **`expired`** when the access token does, and
   the console shows a *Reconnect* button; the platform provider alone
   insists on a refresh token at connect, because a Google connection
   without one is dead in an hour. Provider-specific spellings of "the grant
   is gone" (`invalid_grant`, `bad_refresh_token`,
   `invalid_refresh_token`, `token_revoked`) all map to `revoked`. Revoke is
   RFC 7009 at `revoke_url` where the provider has one, local-only
   otherwise.

5. **Tenant-supplied URLs are fetched server-side, so they are guarded.**
   `Fountain.Connections.UrlGuard` allows `https` only, refuses IP literals,
   `localhost` and the cluster-internal names, and resolves the hostname to
   refuse anything private, link-local, CGNAT or the metadata range — at
   save time and again at every fetch, because DNS changes. Discovery
   applies the guard to every URL the *server* sends back too: a resource
   document that points at the metadata service is the obvious attack.
   `token_hosts` may not carry a wildcard; a bare `*` would attach the
   token to every host the sandbox reaches.

6. **A connection reaches an agent three ways, all through the broker.**
   - The Fountain-served server (Google only): `{"gmail": {"connection":
     id}}` is rewritten at spawn into an HTTP MCP server on Fountain,
     authenticated by the conversation's callback token.
   - A remote MCP server of the tenant's: `{"linear": {"type": "http",
     "url": "https://mcp.linear.app/mcp", "connection": id}}` is rewritten
     into the same entry with `Authorization: Bearer <placeholder>`, and the
     conversation adds an implicit bearer binding for the connection's
     `env_key` to that URL's host. The broker attaches the real token to
     exactly that host and nothing else, and a rotated token is re-uploaded
     at each turn kick (ADR 0019 amendment, rotating secrets).
   - A brokered secret: the access token is a synthetic secret under
     `env_key` (`GITHUB_ACCESS_TOKEN`), placeholder in the sandbox, value at
     the broker, implicit bearer binding to the provider's `token_hosts`. A
     stdio MCP server in the sandbox that reads the env var needs nothing
     new; a binding of the tenant's own on the same name wins.
   None of this exists for an account the broker is not on for: the
   Connections page, the API and the spawn-time rewrite are all gated on
   `Fountain.Broker.enabled_for?/1`, because without the broker the token
   would have to enter the sandbox in the clear, which is the thing
   connections exist to avoid.

7. **Audit.** `connection_provider.created` / `.updated` (changed fields) /
   `.deleted` carry slug, kind and name — never the client secret.
   `connection.created` / `.revoked` / `.expired` carry provider, scopes,
   the account label and the env key — never a token. Refresh-driven
   status changes are attributed to `system:connection_refresh`.

## Consequences

- A tenant can connect any OAuth 2.0 service today by registering an app
  there, and any MCP-spec remote server by pasting its URL. No Fountain
  release is needed per service.
- Fountain owns no app registration but Google's, and carries no
  per-service verification burden. The trade is that the tenant does the
  registration once per service; the console makes it a redirect URI to
  paste and a client id and secret to paste back.
- The `oauth2` kind is deliberately generic and therefore knows nothing
  about a service's tool layer. The Fountain-served tool server exists for
  Gmail alone; every other connection is consumed by a server the tenant
  supplies (remote, or stdio in the sandbox). A per-provider tool layer is
  a separate decision, if ever.
- Device-code and client-credentials grants are out of scope. Both are
  possible additions to `OAuth` as data on the provider row, and neither
  has a caller yet.
- `expired` is a third connection status alongside `active` and `revoked`.
  Anything that renders a status renders three.

## Alternatives considered

- **Fountain-owned OAuth clients per provider, added one at a time.** The
  managed-agent-platform norm. Rejected for the three reasons in the
  context: it does not scale past a handful, it puts Fountain's app in the
  tenant's compliance story, and it duplicates what MCP servers already
  publish. Google stays because #1178 built it and the Gmail tool layer
  needs it; it is the exception that proves the rule.
- **Tenant pastes a token, Fountain brokers it.** Already possible with a
  vault secret and a binding (ADR 0019 gate 1b) and remains the answer for
  a static API key. Rejected as the answer for OAuth'd services because
  the token expires, the refresh is the tenant's problem, and the result
  is the pasted long-lived PAT the whole design is trying to retire.
- **Manual client registration only, no DCR.** Simpler to build. Rejected
  because the MCP authorization spec's promise is *no client id typed
  anywhere*, and a tenant connecting a Linear-style server should get
  exactly that. The manual path stays as the fallback for servers without
  a registration endpoint.
- **A global provider catalog curated by Fountain, with the tenant
  supplying only credentials.** Attractive for consistency. Rejected in
  favour of presets inside a tenant-owned record: a catalog entry that is
  wrong (an endpoint moved, a scope renamed) blocks every tenant until a
  release; a preset is a starting point the tenant can edit.
