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
      # The key stays for JSON-shape compatibility, but on a billing-disabled
      # instance the value is null even for accounts that carry pre-disable
      # residue — there is no subscription for the status to be about (#480).
      subscription_status: if(Fountain.Billing.enabled?(), do: user.subscription_status)
    })
  end
end
