defmodule FountainWeb.Live.Hooks do
  @moduledoc """
  LiveView `on_mount` hooks for multi-tenant authentication.

  ## Usage in router live_session

      live_session :authenticated,
        on_mount: [{FountainWeb.Live.Hooks, :require_authenticated_user}] do
        live "/dashboard", DashboardLive, :index
      end

  ## Hooks

  - `:require_authenticated_user` — halts and redirects to login if no
    current_user is set, or if the user's email is unverified.
  - `:require_admin` — halts if current_user is absent or not an admin.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign_new: 3]

  use FountainWeb, :verified_routes

  alias Fountain.Accounts

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      is_nil(user.email_verified_at) ->
        {:halt,
         socket
         |> put_flash(:error, "Please verify your email address before continuing.")
         |> redirect(to: ~p"/auth/login")}

      true ->
        {:cont, socket}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    if is_nil(user) or user.role != "admin" do
      {:halt, redirect(socket, to: ~p"/auth/login")}
    else
      {:cont, socket}
    end
  end

  # Mount current_user from session into socket assigns without hitting the
  # DB a second time if it was already assigned (e.g. from a previous hook).
  defp mount_current_user(session, socket) do
    assign_new(socket, :current_user, fn ->
      user_id = Map.get(session, "user_id")
      session_version = Map.get(session, "session_version")

      with true <- is_binary(user_id),
           true <- is_integer(session_version),
           %Accounts.User{} = user <- Accounts.get_user(user_id),
           true <- user.session_version == session_version do
        user
      else
        _ -> nil
      end
    end)
  end
end
