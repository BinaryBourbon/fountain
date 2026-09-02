defmodule Managoat.McpAuth do
  @moduledoc """
  MCP authorization discovery and its server-side URL guard.

  `discover/1` follows the authorization chain an MCP server advertises:
  RFC 9728 protected-resource metadata from the server's challenge or
  well-known URL, RFC 8414 authorization-server metadata with the OpenID
  discovery fallback, and RFC 7591 dynamic client registration through
  `register/3` when the server offers it.

  Every URL in that chain passes through `Managoat.McpAuth.UrlGuard`. The
  guard requires HTTPS and a public hostname, including for URLs supplied by
  metadata documents. That last part matters: without it, a malicious resource
  document could point the next discovery request at a cluster's metadata
  service or another private address.
  """

  alias Managoat.McpAuth.Discovery

  @type metadata :: Discovery.metadata()

  @doc delegate_to: {Discovery, :discover, 1}
  defdelegate discover(mcp_url), to: Discovery

  @doc delegate_to: {Discovery, :register, 3}
  defdelegate register(metadata, redirect_uri, opts), to: Discovery
end
