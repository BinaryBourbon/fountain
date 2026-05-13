defmodule FountainWeb.Plugs.OptionalSessionAuth do
  @moduledoc """
  Optionally loads the current user from the session cookie without requiring
  authentication. Sets `conn.assigns.current_user` to the user if a valid
  session exists, or `nil` if not. Never redirects.

  Used on public pages (e.g. the marketing site) that need to show different
  UI for logged-in users without gating access.
  """

  import Plug.Conn

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
      _ -> assign(conn, :current_user, nil)
    end
  end
end
