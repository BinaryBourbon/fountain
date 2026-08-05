defmodule FountainWeb.AuthMeController do
  @moduledoc """
  GET /api/auth/me

  Returns the authenticated user's identity. Used by `fountain auth whoami`
  in the CLI to confirm which account an API key belongs to.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias FountainWeb.Schemas

  tags(["Auth"])

  operation(:show,
    summary: "Identity of the authenticated account",
    description:
      "What the presented bearer token resolves to. `fountain auth whoami` " <>
        "calls this to show which account a key belongs to.",
    responses: [
      ok: {"The account", "application/json", Schemas.AuthMeResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      id: user.id,
      email: user.email,
      role: user.role,
      email_verified: not is_nil(user.email_verified_at),
      # Read side of #525: a client that just bootstrapped an account can see
      # whether the browser will drop this user into the wizard.
      onboarding_state: user.onboarding_state,
      onboarding_completed: not is_nil(user.onboarding_completed_at),
      # The key stays for JSON-shape compatibility, but on a billing-disabled
      # instance the value is null even for accounts that carry pre-disable
      # residue — there is no subscription for the status to be about (#480).
      subscription_status: if(Fountain.Billing.enabled?(), do: user.subscription_status)
    })
  end
end
