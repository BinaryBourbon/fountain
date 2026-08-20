defmodule FountainWeb.OnboardingController do
  @moduledoc """
  Onboarding state over the API (#525).

  `complete_onboarding/1` and `advance_onboarding/2` were called only from the
  wizard LiveView, so an account driven entirely through the API stayed
  permanently un-onboarded: `onboarding_state` never reached `"completed"`.

  The wizard is gone (#867). The console's dashboard stamps the flag when the
  account actually has what it needs — an inference credential and an agent —
  and this endpoint lets a client say so itself. Nothing hard-gates on the
  flag: it is the lifecycle funnel's "onboarded" stage, and this is a small
  write, not a gate.
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
