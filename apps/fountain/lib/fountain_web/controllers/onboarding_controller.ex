defmodule FountainWeb.OnboardingController do
  @moduledoc """
  Onboarding state over the API (#525).

  `complete_onboarding/1` and `advance_onboarding/2` were called only from the
  wizard LiveView, so an account driven entirely through the API stayed
  permanently un-onboarded: `onboarding_state` never reached `"completed"`, and
  a later browser visit to `/onboarding` dropped the user back into the wizard
  they had no reason to see.

  Nothing hard-gates on the flag today — it drives the dashboard banner and the
  post-login redirect — so this is a small write, not a new gate.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Account"])

  operation(:show,
    summary: "Get onboarding state",
    responses: [
      ok: {"Onboarding state", "application/json", Schemas.OnboardingResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    render(conn, :show, user: conn.assigns.current_user)
  end

  operation(:complete,
    summary: "Mark onboarding complete",
    description:
      "Idempotent: completing an already-completed account keeps the original " <>
        "`completed_at` rather than moving it.",
    responses: [
      ok: {"Onboarding state", "application/json", Schemas.OnboardingResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def complete(conn, _params) do
    user = conn.assigns.current_user

    if user.onboarding_completed_at do
      render(conn, :show, user: user)
    else
      with {:ok, updated} <- Accounts.complete_onboarding(user) do
        render(conn, :show, user: updated)
      end
    end
  end
end
