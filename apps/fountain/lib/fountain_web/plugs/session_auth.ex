defmodule FountainWeb.Plugs.SessionAuth do
  @moduledoc """
  Browser/UI auth: checks a `:admin` flag in the session. Single-tenant —
  you log in once with the ADMIN_TOKEN, the server sets the session, and
  every subsequent UI request reads the cookie. Bypassed if already on
  the login page.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  use FountainWeb, :verified_routes

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :admin) == true do
      conn
    else
      conn
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc "LiveView on_mount hook: enforce session auth + track current path."
  def on_mount(:require_admin, _params, session, socket) do
    if Map.get(session, "admin") == true do
      socket =
        Phoenix.LiveView.attach_hook(socket, :current_path, :handle_params, fn
          _params, uri, socket ->
            path = URI.parse(uri).path
            {:cont, Phoenix.Component.assign(socket, :current_path, path)}
        end)

      {:cont, Phoenix.Component.assign(socket, :current_path, "/")}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end
end
