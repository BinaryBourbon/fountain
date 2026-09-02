ExUnit.start()

unless Application.get_env(:managoat_mcp_auth, :req_options) do
  Application.put_env(
    :managoat_mcp_auth,
    :req_options,
    plug: {Req.Test, Managoat.McpAuth}
  )
end

if Application.fetch_env(:managoat_mcp_auth, :allow_private_hosts) == :error do
  Application.put_env(:managoat_mcp_auth, :allow_private_hosts, true)
end
