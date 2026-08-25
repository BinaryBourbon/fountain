defmodule FountainWeb.ConnectionsController do
  @moduledoc """
  The OAuth round trip that connects a provider account to the signed-in
  user (#1178). `start` sends the browser to the provider's consent screen
  with a signed `state`; `callback` verifies it, exchanges the code and
  stores the grant through `Fountain.Connections`. Both end on the
  Connections page with a flash, so the LiveView stays a plain list.

  `state` is a `Phoenix.Token` over the user id and a nonce kept in the
  session: the callback belongs to the session that started it, and a code
  delivered to another session is refused.
  """
  use FountainWeb, :controller

  alias Fountain.{Broker, Connections}
  alias Fountain.Connections.Google
  alias FountainWeb.Audited

  @state_salt "connections:oauth_state"
  @state_max_age 600

  plug :require_connections

  def start(conn, %{"provider" => "google"}) do
    if Google.configured?() do
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      state = Phoenix.Token.sign(conn, @state_salt, {conn.assigns.current_user.id, nonce})

      conn
      |> put_session(:connections_oauth_nonce, nonce)
      |> redirect(external: Google.authorize_url(redirect_uri(conn, "google"), state))
    else
      back(conn, :error, "Google connections are not configured on this deployment.")
    end
  end

  def start(conn, _params), do: back(conn, :error, "Unknown provider.")

  def callback(conn, %{"provider" => "google", "code" => code, "state" => state}) do
    user = conn.assigns.current_user
    nonce = get_session(conn, :connections_oauth_nonce)
    conn = delete_session(conn, :connections_oauth_nonce)

    with {:ok, {uid, ^nonce}} when uid == user.id and is_binary(nonce) <-
           Phoenix.Token.verify(conn, @state_salt, state, max_age: @state_max_age),
         {:ok, grant} <- Google.exchange_code(code, redirect_uri(conn, "google")),
         {:ok, connection} <-
           Connections.connect(user.id, "google", grant, Audited.attribution(conn)) do
      back(conn, :info, "Connected #{connection.account_email}.")
    else
      {:ok, _other} ->
        back(conn, :error, "That sign-in did not start from this session. Try again.")

      {:error, :no_refresh_token} ->
        back(
          conn,
          :error,
          "Google returned no refresh token. Remove Fountain from your Google account's " <>
            "third-party access and connect again."
        )

      {:error, reason} ->
        back(conn, :error, "Google sign-in failed: #{describe(reason)}")
    end
  end

  def callback(conn, %{"provider" => "google", "error" => error}) do
    _ = delete_session(conn, :connections_oauth_nonce)
    back(conn, :error, "Google sign-in was not completed (#{error}).")
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

  defp redirect_uri(_conn, provider),
    do: Fountain.PublicUrl.base() <> "/connections/#{provider}/callback"

  defp back(conn, kind, message) do
    conn |> put_flash(kind, message) |> redirect(to: ~p"/account/connections")
  end

  defp describe(:invalid_grant), do: "the code was refused"
  defp describe({:http, status, _body}), do: "Google answered #{status}"
  defp describe({:userinfo, status, _body}), do: "could not read the account's address (#{status})"
  defp describe(%Ecto.Changeset{} = cs), do: cs.errors |> Keyword.keys() |> Enum.join(", ")
  defp describe(reason), do: inspect(reason)
end
