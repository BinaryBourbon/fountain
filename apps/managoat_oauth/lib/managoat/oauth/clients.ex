defmodule Managoat.OAuth.Clients do
  @moduledoc """
  The public-client registry: a list in configuration, not a table. Each
  client is an id, a display name and the redirect URIs it may be sent to,
  matched **exactly**. Public clients have no secret; the allowlist and PKCE
  are the whole binding between a code and the app that asked for it.
  """

  @type client :: %{id: String.t(), name: String.t(), redirect_uris: [String.t()]}

  @doc """
  Normalise a configured client list: atom or string keys, `name` falling
  back to `id`, every value a string. What `redirect_uris` a JSON registry
  decoded into is accepted as it is.
  """
  @spec normalize([map()]) :: [client()]
  def normalize(clients) when is_list(clients) do
    Enum.map(clients, fn c ->
      id = to_string(get(c, :id))

      %{
        id: id,
        name: to_string(get(c, :name) || id),
        redirect_uris: Enum.map(get(c, :redirect_uris) || [], &to_string/1)
      }
    end)
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(kw, key) when is_list(kw), do: Keyword.get(kw, key)

  @doc "The client with `id`, or nil."
  @spec get_client([client()], term()) :: client() | nil
  def get_client(clients, id) when is_binary(id), do: Enum.find(clients, &(&1.id == id))
  def get_client(_clients, _), do: nil

  @doc """
  The distinct origins (`scheme://host[:port]`) of every client's redirect
  URIs, for a consent page's `form-action` CSP.
  """
  @spec redirect_origins([client()]) :: [String.t()]
  def redirect_origins(clients) do
    clients
    |> Enum.flat_map(& &1.redirect_uris)
    |> Enum.map(&origin_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp origin_of(uri) do
    case URI.parse(uri) do
      %URI{scheme: s, host: h} = u when is_binary(s) and is_binary(h) ->
        port = if u.port && u.port != URI.default_port(s), do: ":#{u.port}", else: ""
        "#{s}://#{h}#{port}"

      _ ->
        nil
    end
  end

  @doc """
  Validate an authorization request's identity part against the registry:
  `{:ok, client}` or `{:error, :unknown_client | :redirect_uri_mismatch |
  :unsupported_code_challenge_method | :invalid_code_challenge}`.
  """
  @spec validate_request([client()], map()) :: {:ok, client()} | {:error, atom()}
  def validate_request(clients, params) when is_map(params) do
    with %{} = client <- get_client(clients, params["client_id"]) || {:error, :unknown_client},
         true <-
           params["redirect_uri"] in client.redirect_uris || {:error, :redirect_uri_mismatch},
         true <-
           (params["code_challenge_method"] || "S256") == "S256" ||
             {:error, :unsupported_code_challenge_method},
         true <- valid_challenge?(params["code_challenge"]) || {:error, :invalid_code_challenge} do
      {:ok, client}
    end
  end

  # 43..128 chars of the base64url alphabet — a S256 challenge is 43.
  defp valid_challenge?(c) when is_binary(c), do: Regex.match?(~r/^[A-Za-z0-9._~-]{43,128}$/, c)
  defp valid_challenge?(_), do: false
end
