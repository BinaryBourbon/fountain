defmodule FountainWeb.Plugs.RequireAdminApi do
  @moduledoc """
  The bearer-token analogue of `Live.Hooks.require_admin` (#527).

  Layered on top of `:api` (which authenticates the key and loads the user) and
  `:require_full_scope` (which keeps a sandbox's per-conversation token out).
  This plug is the last of the three: operator powers need an admin, a
  human-held credential, and both checks passing.

  A non-admin gets 403 rather than 404. There is nothing to hide — the admin
  API's existence is documented — and a 404 would make "you are not an admin"
  indistinguishable from "that endpoint moved", which is a bad half-hour during
  an incident.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{role: "admin"}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "admin_required",
      message: "This endpoint requires an account with the admin role."
    })
    |> halt()
  end
end
