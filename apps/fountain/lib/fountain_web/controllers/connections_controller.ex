defmodule FountainWeb.ConnectionsController do
  @moduledoc """
  The OAuth round trip that connects a provider account to the signed-in
  user (#1178, #1186). `start` sends the browser to the provider's consent
  screen with a signed `state`; `callback` verifies it, exchanges the code
  and stores the grant through `Fountain.Connections`. Both end on the
  Connections page with a flash, so the LiveView stays a plain list.

  `:provider` is `google` (the platform provider) or a tenant provider's id;
  the redirect URI carries the same segment, which is what the tenant
  pastes into their app registration.

  `state` is a `Phoenix.Token` over the user id and a nonce kept in the
  session: the callback belongs to the session that started it, and a code
  delivered to another session is refused. The PKCE verifier, where the
  provider uses one, rides in the session beside the nonce and is spent on
  the callback.
  """
  use FountainWeb, :controller

  alias Fountain.{Broker, Connections}
  alias Fountain.Connections.{OAuth, Provider}
  alias FountainWeb.Audited

  @state_salt "connections:oauth_state"
  @state_max_age 600

  plug :require_connections

  def start(conn, %{"provider" => provider_id} = params) do
    user = conn.assigns.current_user

    with %Provider{} = provider <- Connections.get_provider(provider_id, user.id) || :unknown,
         {:ok, provider} <- Connections.unlock_provider(provider),
         true <- OAuth.configured?(provider) || :unconfigured do
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      verifier = if provider.pkce, do: OAuth.code_verifier()
      state = Phoenix.Token.sign(conn, @state_salt, {user.id, nonce})

      conn
      |> put_session(:connections_oauth, %{
        "nonce" => nonce,
        "provider" => provider.id,
        "verifier" => verifier,
        "label" => blank_to_nil(params["label"])
      })
      |> redirect(external: OAuth.authorize_url(provider, redirect_uri(provider), state, verifier))
    else
      :unknown ->
        back(conn, :error, "Unknown provider.")

      :unconfigured ->
        back(conn, :error, "#{provider_name(provider_id, user.id)} has no OAuth client yet.")

      {:error, reason} ->
        back(conn, :error, "Could not start: #{describe(reason)}")
    end
  end

  def callback(conn, %{"provider" => provider_id, "code" => code, "state" => state}) do
    user = conn.assigns.current_user
    started = get_session(conn, :connections_oauth) || %{}
    conn = delete_session(conn, :connections_oauth)
    nonce = started["nonce"]

    with {:ok, {uid, ^nonce}} when uid == user.id and is_binary(nonce) <-
           Phoenix.Token.verify(conn, @state_salt, state, max_age: @state_max_age),
         true <- started["provider"] == provider_id || :wrong_provider,
         %Provider{} = provider <- Connections.get_provider(provider_id, user.id) || :unknown,
         {:ok, provider} <- Connections.unlock_provider(provider),
         {:ok, grant} <-
           OAuth.exchange_code(provider, code, redirect_uri(provider), started["verifier"]),
         {:ok, connection} <-
           Connections.connect(
             user.id,
             provider,
             grant,
             [account_label: started["label"]] ++ Audited.attribution(conn)
           ) do
      back(conn, :info, "Connected #{connection.account_email}.")
    else
      {:ok, _other} ->
        back(conn, :error, "That sign-in did not start from this session. Try again.")

      :wrong_provider ->
        back(conn, :error, "That sign-in started for a different provider. Try again.")

      :unknown ->
        back(conn, :error, "Unknown provider.")

      {:error, :no_refresh_token} ->
        back(
          conn,
          :error,
          "The provider returned no refresh token. Remove Fountain from the account's " <>
            "third-party access and connect again."
        )

      {:error, reason} ->
        back(conn, :error, "#{provider_name(provider_id, user.id)} sign-in failed: #{describe(reason)}")
    end
  end

  def callback(conn, %{"provider" => provider_id, "error" => error}) do
    conn = delete_session(conn, :connections_oauth)
    user = conn.assigns.current_user
    back(conn, :error, "#{provider_name(provider_id, user.id)} sign-in was not completed (#{error}).")
  end

  def callback(conn, _params), do: back(conn, :error, "Unknown provider or a malformed callback.")

  # The feature is for brokered accounts only: without the broker the token
  # would have to enter a sandbox in the clear.
  defp require_connections(conn, _opts) do
    if Broker.enabled_for?(conn.assigns.current_user.id) do
      conn
    else
      conn
      |> put_flash(:error, "Connections are not enabled for this account.")
      |> redirect(to: ~p"/account")
      |> halt()
    end
  end

  defp redirect_uri(%Provider{} = provider), do: Connections.redirect_uri(provider)

  defp provider_name(id, user_id) do
    case Connections.get_provider(id, user_id) do
      %Provider{name: name} -> name
      _ -> "The provider"
    end
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: String.slice(v, 0, 320)

  defp back(conn, kind, message) do
    conn |> put_flash(kind, message) |> redirect(to: ~p"/account/connections")
  end

  defp describe(:invalid_grant), do: "the code was refused"
  defp describe({:http, status, _body}), do: "the provider answered #{status}"
  defp describe({:unsafe_url, reason}), do: "the provider's URL #{Connections.UrlGuard.message(reason)}"

  defp describe({:userinfo, :no_label, path}),
    do: "the account name was not at `#{path}` in the userinfo response"

  defp describe({:userinfo, status, _body}),
    do: "could not read the account's name (#{status})"

  defp describe(%Ecto.Changeset{} = cs), do: cs.errors |> Keyword.keys() |> Enum.join(", ")
  defp describe(reason), do: inspect(reason)
end
