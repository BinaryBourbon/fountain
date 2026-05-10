defmodule FountainWeb.Plugs.TenantSessionAuth do
  @moduledoc """
  Browser pipeline auth: reads `user_id` and `session_version` from the
  session cookie, loads the user, validates `session_version` matches (so
  password resets invalidate existing sessions), and sets
  `conn.assigns.current_user`.

  Redirects to `/auth/login` if the session is absent or stale.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  use FountainWeb, :verified_routes

  alias Fountain.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    session_version = get_session(conn, :session_version)

    with true <- is_binary(user_id),
         true <- is_integer(session_version),
         %Accounts.User{} = user <- Accounts.get_user(user_id),
         true <- user.session_version == session_version do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> redirect(to: ~p"/auth/login")
        |> halt()
    end
  end
end
