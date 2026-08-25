defmodule FountainWeb.ConnectionProviderJSON do
  @moduledoc "JSON views for connection providers (#1186). Never a client secret."

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Provider, UrlGuard}

  def index(%{providers: providers}), do: %{data: Enum.map(providers, &summary/1)}

  def show(%{provider: p}), do: summary(p)

  @doc "One provider, as the API and the console see it."
  def summary(%Provider{} = p) do
    %{
      id: p.id,
      slug: p.slug,
      name: p.name,
      kind: p.kind,
      platform: Provider.platform?(p),
      configured: configured?(p),
      authorize_url: p.authorize_url,
      token_url: p.token_url,
      revoke_url: p.revoke_url,
      userinfo_url: p.userinfo_url,
      account_label_path: p.account_label_path,
      scopes: p.scopes,
      client_id: p.client_id,
      has_client_secret: not is_nil(p.client_secret_ciphertext) or is_binary(p.client_secret),
      token_endpoint_auth: p.token_endpoint_auth,
      pkce: p.pkce,
      env_key: p.env_key,
      token_hosts: p.token_hosts,
      mcp_url: p.mcp_url,
      issuer: p.issuer,
      client_source: p.client_source,
      registration_endpoint: p.mcp_metadata["registration_endpoint"],
      redirect_uri: Connections.redirect_uri(p),
      connect_url: Fountain.PublicUrl.base() <> "/connections/#{p.id}/start",
      created_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  # A tenant row is configured when it has a client id and, unless it is a
  # public client, a stored secret; the platform provider when its env vars
  # are set.
  defp configured?(%Provider{user_id: nil} = p), do: OAuth.configured?(p)

  defp configured?(%Provider{} = p) do
    present?(p.client_id) and
      (p.token_endpoint_auth == "none" or not is_nil(p.client_secret_ciphertext))
  end

  defp present?(v), do: is_binary(v) and v != ""

  @doc "A discovery or registration failure, in words."
  def describe({:discovery, message}) when is_binary(message), do: message
  def describe({:unsafe_url, url, reason}), do: "#{url} #{UrlGuard.message(reason)}"
  def describe({:unsafe_url, reason}), do: "the URL #{UrlGuard.message(reason)}"
  def describe({:mcp_server, status}) when is_integer(status), do: "the MCP server answered #{status}"
  def describe({:mcp_server, reason}), do: "the MCP server could not be reached: #{inspect(reason)}"

  def describe({:metadata, url, status}) when is_integer(status),
    do: "#{url} answered #{status}"

  def describe({:metadata, url, reason}), do: "#{url}: #{inspect(reason)}"
  def describe(:no_authorization_server), do: "the resource metadata names no authorization server"

  def describe({:authorization_server, issuer, :no_metadata}),
    do: "#{issuer} publishes no authorization server metadata"

  def describe(:incomplete_authorization_server_metadata),
    do: "the authorization server metadata has no authorize or token endpoint"

  def describe({:registration, status, body}) when is_integer(status),
    do: "client registration answered #{status}: #{inspect(body)}"

  def describe({:registration, reason}), do: "client registration failed: #{inspect(reason)}"
  def describe(:no_registration_endpoint), do: "the authorization server offers no client registration"
  def describe(reason), do: inspect(reason)
end
