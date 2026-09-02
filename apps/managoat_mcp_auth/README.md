# Managoat.McpAuth

MCP authorization discovery with a server-side URL guard.

The discovery chain follows the MCP authorization specification:

1. RFC 9728 protected-resource metadata comes from the MCP server's `401`
   challenge, its path-specific well-known URL, or the origin fallback.
2. RFC 8414 authorization-server metadata supplies the authorization, token,
   revocation, and optional registration endpoints. OpenID Connect's
   `openid-configuration` is the fallback.
3. RFC 7591 dynamic client registration creates a client when the server
   offers a registration endpoint.

Every fetched URL must use HTTPS, name a hostname rather than an IP literal,
and resolve without any loopback, private, link-local, CGNAT, or metadata
address. The guard applies to URLs returned by metadata too: a malicious
protected-resource document could otherwise point the next discovery request
at the cluster's metadata service.

```elixir
{:ok, metadata} = Managoat.McpAuth.discover("https://mcp.example/mcp")
opts = [client_name: "My client", client_uri: "https://client.example"]
{:ok, client} =
  Managoat.McpAuth.register(metadata, "https://client.example/callback", opts)
client["client_id"]
```

The library reads optional defaults from its own application environment:
`config :managoat_mcp_auth, timeout_ms: 15_000, req_options: [],
allow_private_hosts: false`. Prefer the `allow_private_hosts:` option on
`Managoat.McpAuth.UrlGuard.check/2` when a test only needs to bypass DNS
resolution.

## Licence

Apache-2.0. See `LICENSE`.
