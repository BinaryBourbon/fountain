defmodule FountainWeb.AuthMeController do
  @moduledoc """
  GET /api/auth/me

  Returns the authenticated user's identity. Used by `fountain auth whoami`
  in the CLI to confirm which account an API key belongs to.
  """

  use FountainWeb, :controller

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      id: user.id,
      email: user.email,
      role: user.role,
      subscription_status: user.subscription_status
    })
  end
end
