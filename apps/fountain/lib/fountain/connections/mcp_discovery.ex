defmodule Fountain.Connections.McpDiscovery do
  @moduledoc """
  How Fountain learns where a remote MCP server's authorization lives
  (#1186), the way the MCP authorization spec says:

  1. `GET` the MCP URL with no credential. A conforming server answers
     `401` with `WWW-Authenticate: Bearer resource_metadata="…"` naming its
     protected-resource metadata (RFC 9728). A server that names none is
     tried at the well-known path for its URL, then at the origin's.
  2. That document's `authorization_servers` names the issuer; its RFC 8414
     metadata (`/.well-known/oauth-authorization-server`, with the OpenID
     `/.well-known/openid-configuration` as the fallback) carries the
     authorize, token, revocation and registration endpoints.
  3. `register/2`: RFC 7591 dynamic client registration at
     `registration_endpoint`, so the tenant types no client id anywhere.
     The server picks the client's auth method; a public client comes back
     with no secret and `token_endpoint_auth_method: none`.

  Every URL, including the ones the server sent back, passes
  `Fountain.Connections.UrlGuard` before it is fetched: a malicious
  resource document that points discovery at the metadata service is the
  obvious trick. Each fetch has a timeout and the chain follows no
  redirects.
  """

  alias Fountain.Connections.UrlGuard

  @type metadata :: %{String.t() => term()}

  @doc """
  The merged metadata for an MCP server URL: `resource`, `issuer`,
  `authorization_endpoint`, `token_endpoint`, `revocation_endpoint`,
  `registration_endpoint`, `scopes`, `code_challenge_methods_supported`,
  `token_endpoint_auth_methods_supported`, plus the raw documents under
  `resource_metadata` and `authorization_server_metadata`.
  """
  @spec discover(String.t()) :: {:ok, metadata()} | {:error, term()}
  def discover(mcp_url) when is_binary(mcp_url) do
    with :ok <- guard(mcp_url),
         {:ok, rm_url} <- resource_metadata_url(mcp_url),
         {:ok, rm} <- fetch_json(rm_url),
         {:ok, issuer} <- authorization_server(rm),
         {:ok, as} <- authorization_server_metadata(issuer),
         :ok <- require_endpoints(as) do
      {:ok,
       %{
         "resource" => rm["resource"] || mcp_url,
         "issuer" => as["issuer"] || issuer,
         "authorization_endpoint" => as["authorization_endpoint"],
         "token_endpoint" => as["token_endpoint"],
         "revocation_endpoint" => as["revocation_endpoint"],
         "registration_endpoint" => as["registration_endpoint"],
         "scopes" => scopes(rm, as),
         "code_challenge_methods_supported" => as["code_challenge_methods_supported"] || [],
         "token_endpoint_auth_methods_supported" =>
           as["token_endpoint_auth_methods_supported"] || [],
         "resource_metadata" => rm,
         "authorization_server_metadata" => as
       }}
    end
  end

  # Step 1: the 401 challenge, or the well-known paths.
  defp resource_metadata_url(mcp_url) do
    case Req.get(req(), url: mcp_url) do
      {:ok, %{status: 401, headers: headers}} ->
        case challenge_resource_metadata(headers) do
          nil -> {:ok, well_known_resource(mcp_url)}
          url -> {:ok, url}
        end

      {:ok, %{status: status}} when status in [200, 400, 403, 404, 405, 406] ->
        # Some servers answer a bare GET without a challenge; the well-known
        # path still tells us whether they are protected at all.
        {:ok, well_known_resource(mcp_url)}

      {:ok, %{status: status}} ->
        {:error, {:mcp_server, status}}

      {:error, reason} ->
        {:error, {:mcp_server, reason}}
    end
  end

  defp challenge_resource_metadata(headers) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == "www-authenticate" end)
    |> Enum.flat_map(fn {_, v} -> List.wrap(v) end)
    |> Enum.find_value(fn value ->
      case Regex.run(~r/resource_metadata\s*=\s*"?([^",\s]+)"?/i, to_string(value)) do
        [_, url] -> url
        _ -> nil
      end
    end)
  end

  # RFC 9728 §3.1: `/.well-known/oauth-protected-resource` plus the
  # resource's path, falling back to the origin's document.
  defp well_known_resource(mcp_url) do
    uri = URI.parse(mcp_url)
    path = String.trim_trailing(uri.path || "", "/")
    origin = %{uri | path: nil, query: nil, fragment: nil, userinfo: nil}

    if path in ["", "/"],
      do: URI.to_string(%{origin | path: "/.well-known/oauth-protected-resource"}),
      else: {URI.to_string(%{origin | path: "/.well-known/oauth-protected-resource" <> path}),
             URI.to_string(%{origin | path: "/.well-known/oauth-protected-resource"})}
  end

  defp fetch_json({first, fallback}) do
    case fetch_json(first) do
      {:ok, _} = ok -> ok
      {:error, _} -> fetch_json(fallback)
    end
  end

  defp fetch_json(url) when is_binary(url) do
    with :ok <- guard(url) do
      case Req.get(req(), url: url, headers: [accept: "application/json"]) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: 200, body: body}} when is_binary(body) -> decode(body, url)
        {:ok, %{status: status}} -> {:error, {:metadata, url, status}}
        {:error, reason} -> {:error, {:metadata, url, reason}}
      end
    end
  end

  defp decode(body, url) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:metadata, url, :not_json}}
    end
  end

  defp authorization_server(%{"authorization_servers" => [issuer | _]}) when is_binary(issuer),
    do: {:ok, issuer}

  defp authorization_server(_), do: {:error, :no_authorization_server}

  # Step 2: RFC 8414 (issuer path folded into the well-known path), then
  # OpenID Connect discovery.
  defp authorization_server_metadata(issuer) do
    with :ok <- guard(issuer) do
      uri = URI.parse(issuer)
      path = String.trim_trailing(uri.path || "", "/")
      origin = %{uri | path: nil, query: nil, fragment: nil, userinfo: nil}

      candidates =
        [
          "/.well-known/oauth-authorization-server" <> path,
          path <> "/.well-known/openid-configuration",
          "/.well-known/oauth-authorization-server",
          "/.well-known/openid-configuration"
        ]
        |> Enum.uniq()
        |> Enum.map(&URI.to_string(%{origin | path: &1}))

      Enum.reduce_while(candidates, {:error, {:authorization_server, issuer, :no_metadata}}, fn url,
                                                                                               acc ->
        case fetch_json(url) do
          {:ok, md} -> {:halt, {:ok, md}}
          _ -> {:cont, acc}
        end
      end)
    end
  end

  defp require_endpoints(%{"authorization_endpoint" => a, "token_endpoint" => t})
       when is_binary(a) and is_binary(t) do
    with :ok <- guard(a), do: guard(t)
  end

  defp require_endpoints(_), do: {:error, :incomplete_authorization_server_metadata}

  # The resource's own scopes first (they are what the server will accept),
  # else what the AS advertises.
  defp scopes(rm, as) do
    case rm["scopes_supported"] do
      [_ | _] = s -> s
      _ -> List.wrap(as["scopes_supported"])
    end
  end

  @doc """
  Register a client at the authorization server (RFC 7591) and return the
  provider attributes it yields: `client_id`, `client_secret` (absent for
  a public client), `token_endpoint_auth` and `client_source: "dcr"`.
  """
  @spec register(metadata(), String.t()) :: {:ok, map()} | {:error, term()}
  def register(%{"registration_endpoint" => endpoint} = md, redirect_uri)
      when is_binary(endpoint) and is_binary(redirect_uri) do
    with :ok <- guard(endpoint) do
      body = %{
        "client_name" => "Fountain",
        "client_uri" => Fountain.PublicUrl.base(),
        "redirect_uris" => [redirect_uri],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => preferred_auth(md),
        "scope" => Enum.join(md["scopes"] || [], " ")
      }

      case Req.post(req(), url: endpoint, json: body, headers: [accept: "application/json"]) do
        {:ok, %{status: status, body: %{"client_id" => id} = resp}}
        when status in 200..299 and is_binary(id) ->
          {:ok,
           %{
             "client_id" => id,
             "client_secret" => resp["client_secret"],
             "token_endpoint_auth" => auth_method(resp),
             "client_source" => "dcr"
           }}

        {:ok, %{status: status, body: body}} ->
          {:error, {:registration, status, body}}

        {:error, reason} ->
          {:error, {:registration, reason}}
      end
    end
  end

  def register(_md, _redirect_uri), do: {:error, :no_registration_endpoint}

  # Ask for a confidential client where the server offers one; a public
  # client (PKCE only) where that is all it does.
  defp preferred_auth(md) do
    supported = md["token_endpoint_auth_methods_supported"] || []

    cond do
      supported == [] -> "client_secret_post"
      "client_secret_post" in supported -> "client_secret_post"
      "client_secret_basic" in supported -> "client_secret_basic"
      true -> "none"
    end
  end

  defp auth_method(%{"token_endpoint_auth_method" => m})
       when m in ["client_secret_post", "client_secret_basic", "none"],
       do: m

  defp auth_method(%{"client_secret" => s}) when is_binary(s) and s != "", do: "client_secret_post"
  defp auth_method(_), do: "none"

  defp guard(url) do
    case UrlGuard.check(url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_url, url, reason}}
    end
  end

  @doc false
  def req do
    Req.new(
      [
        receive_timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000),
        retry: false,
        redirect: false
      ] ++ Application.get_env(:fountain, :connections_req_options, [])
    )
  end
end
