defmodule Fountain.Connections.Google do
  @moduledoc """
  The Google side of a connection (#1178): the authorization-code flow that
  turns a tenant's consent into a refresh token, the refresh call that turns
  that into an access token, and the revoke call. A plain OAuth client over
  `Req`; nothing here touches the database.

  `access_type=offline` and `prompt=consent` are sent on every authorize
  URL: without both, Google returns no refresh token on a second consent,
  and a connection with no refresh token is dead in an hour.

  Configured by `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`.
  Unset, `configured?/0` is false and the console shows the feature as not
  available on this deployment.
  """

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @revoke_url "https://oauth2.googleapis.com/revoke"
  @userinfo_url "https://openidconnect.googleapis.com/v1/userinfo"

  # gmail.modify covers read, send, reply and label; the two OpenID scopes
  # give the account's address, which is how a connection is named.
  @scopes ~w(openid email https://www.googleapis.com/auth/gmail.modify)

  # The hosts the brokered access token is attached to as a bearer (ADR
  # 0019), so an MCP server the tenant runs in the sandbox reaches Gmail
  # with a placeholder in its environment.
  @token_hosts ~w(gmail.googleapis.com www.googleapis.com)

  def provider, do: "google"
  def scopes, do: @scopes
  def token_hosts, do: @token_hosts

  @doc "The env var name a Google connection's access token is brokered under."
  def env_key, do: "GOOGLE_ACCESS_TOKEN"

  def client_id, do: Application.get_env(:fountain, :google_oauth_client_id)
  def client_secret, do: Application.get_env(:fountain, :google_oauth_client_secret)

  @doc "True when both halves of the OAuth client are set."
  def configured? do
    present?(client_id()) and present?(client_secret())
  end

  defp present?(v), do: is_binary(v) and v != ""

  @doc "Where to send the tenant. `state` is verified on the way back by the caller."
  def authorize_url(redirect_uri, state) when is_binary(redirect_uri) and is_binary(state) do
    query =
      URI.encode_query(%{
        "client_id" => client_id() || "",
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(@scopes, " "),
        "access_type" => "offline",
        "prompt" => "consent",
        "include_granted_scopes" => "true",
        "state" => state
      })

    @authorize_url <> "?" <> query
  end

  @doc """
  Exchange the code from the callback for tokens. Returns
  `{:ok, %{refresh_token, access_token, expires_at, scopes, account_email}}`.
  """
  def exchange_code(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    form = %{
      "code" => code,
      "client_id" => client_id() || "",
      "client_secret" => client_secret() || "",
      "redirect_uri" => redirect_uri,
      "grant_type" => "authorization_code"
    }

    with {:ok, %{"access_token" => access} = body} <- token_request(form),
         {:ok, refresh} <- fetch_refresh_token(body),
         {:ok, email} <- account_email(access) do
      {:ok,
       %{
         refresh_token: refresh,
         access_token: access,
         expires_at: expires_at(body["expires_in"]),
         scopes: String.split(body["scope"] || "", " ", trim: true),
         account_email: email
       }}
    else
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = err -> err
    end
  end

  defp fetch_refresh_token(%{"refresh_token" => refresh})
       when is_binary(refresh) and refresh != "",
       do: {:ok, refresh}

  defp fetch_refresh_token(_), do: {:error, :no_refresh_token}

  @doc """
  A fresh access token for a refresh token: `{:ok, access_token, expires_at}`,
  `{:error, :invalid_grant}` when Google has forgotten the grant (the tenant
  revoked it, or the password changed), or `{:error, reason}`.
  """
  def refresh(refresh_token) when is_binary(refresh_token) do
    form = %{
      "refresh_token" => refresh_token,
      "client_id" => client_id() || "",
      "client_secret" => client_secret() || "",
      "grant_type" => "refresh_token"
    }

    case token_request(form) do
      {:ok, %{"access_token" => access} = body} -> {:ok, access, expires_at(body["expires_in"])}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Tell Google to forget the grant. Best effort: an already-revoked token is a
  400 there and `:ok` here, because the outcome is the same.
  """
  def revoke(token) when is_binary(token) do
    case Req.post(req(), url: @revoke_url, form: [token: token]) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 400}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token_request(form) do
    case Req.post(req(), url: @token_url, form: form) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"}}} when status in 400..499 ->
        {:error, :invalid_grant}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp account_email(access_token) do
    case Req.get(req(), url: @userinfo_url, auth: {:bearer, access_token}) do
      {:ok, %{status: 200, body: %{"email" => email}}} when is_binary(email) -> {:ok, email}
      {:ok, %{status: status, body: body}} -> {:error, {:userinfo, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expires_at(ttl) when is_integer(ttl),
    do: DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.truncate(:second)

  defp expires_at(_), do: expires_at(3600)

  @doc false
  def req do
    Req.new(
      [
        receive_timeout: Application.get_env(:fountain, :google_oauth_timeout_ms, 15_000),
        retry: false
      ] ++ Application.get_env(:fountain, :google_oauth_req_options, [])
    )
  end
end
