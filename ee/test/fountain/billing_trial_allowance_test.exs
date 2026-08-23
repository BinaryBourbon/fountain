defmodule Fountain.BillingTrialAllowanceTest do
  @moduledoc """
  The turn-hour allowance during a trial (#1016 + trial limits).

  `turn_hour_allowance/2` is the single shape all three surfaces render, so if
  it reads the wrong plan every one of them shows a trialing customer the paid
  tier's number. It reached the catalog through `user.plan` — a bare slug,
  which carries no subscription status and therefore cannot be trial-aware.
  That is the bug this file exists to keep fixed.
  """
  use Fountain.DataCase, async: false

  alias Fountain.{Billing, Plans}

  setup do
    previous = Application.get_env(:fountain, :billing_enabled)
    Application.put_env(:fountain, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :billing_enabled, previous) end)
    :ok
  end

  defp user_on(plan, status) do
    user = insert_verified_user(plan: plan)

    {:ok, user} =
      user
      |> Fountain.Accounts.User.billing_changeset(%{subscription_status: status})
      |> Repo.update()

    user
  end

  test "a trialing account is measured against the trial's hours, not its tier's" do
    user = user_on("scale", "trialing")

    allowance = Billing.turn_hour_allowance(user)

    assert allowance.included == Plans.fetch!("trial").included_turn_hours
    assert allowance.included == 40
    refute allowance.included == Plans.fetch!("scale").included_turn_hours
  end

  test "the same account on that tier gets the tier's hours" do
    user = user_on("scale", "active")

    assert Billing.turn_hour_allowance(user).included ==
             Plans.fetch!("scale").included_turn_hours
  end

  # The allowance is smaller during a trial, so `over?` can be true for a
  # trialing account that would be well inside its tier. That is the intended
  # behaviour — nothing is enforced, but the number has to be honest.
  test "over? is computed against the trial's smaller allowance" do
    user = user_on("scale", "trialing")
    allowance = Billing.turn_hour_allowance(user)

    assert allowance.remaining == Float.round(max(40 - allowance.used, 0.0), 2)
  end

  test "billing disabled means the tier's hours even while trialing" do
    user = user_on("scale", "trialing")
    Application.put_env(:fountain, :billing_enabled, false)

    assert Billing.turn_hour_allowance(user).included ==
             Plans.fetch!("scale").included_turn_hours
  end
end
