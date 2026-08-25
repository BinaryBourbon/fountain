defmodule Fountain.Billing.TurnHoursTest do
  @moduledoc """
  The billing period, and the turn-hour allowance measured over it (#1016).

  Two things are easy to get wrong here and both are tested hard. The window
  has to be the one Stripe invoices — or say out loud that it is not — because
  an allowance reported over a calendar month a customer is not charged for is
  a support ticket per customer per month. And the unit has to be *turn* time:
  an idle sandbox costs Fountain money but spends none of a tenant's hours,
  and a tenant's own runner costs Fountain nothing at all.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Billing
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Conversations

  # A period wholly in the past, so `attribution/3`'s ceiling is the period end
  # rather than the wall clock and every expected figure is exact.
  @period_start ~U[2026-05-01 00:00:00Z]
  @period_end ~U[2026-06-01 00:00:00Z]

  defp sandbox_running(user, provider, started, ended) do
    insert_sandbox(
      user_id: user.id,
      provider: provider,
      status: "terminated",
      inserted_at: started,
      terminated_at: ended
    )
  end

  defp turn(sandbox, user, started_at, ended_at) do
    agent = insert_agent(user_id: user.id)
    conversation = insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

    {:ok, _} =
      Conversations._unsafe_create_turn(%{
        conversation_id: conversation.id,
        turn_number: System.unique_integer([:positive]),
        prompt: "hello",
        status: "completed",
        started_at: started_at,
        ended_at: ended_at
      })
  end

  describe "billing_period/2" do
    test "falls back to the calendar month, and says so, with no period stored" do
      user = insert_verified_user()

      period = Billing.billing_period(user, ~U[2026-06-05 00:00:00Z])

      assert period.source == :calendar_month
      assert period.start.day == 1
    end
  end

  describe "turn_hours_used/2" do
    test "counts time with a prompt in flight, not the sandbox's whole life" do
      user = insert_verified_user()

      sandbox =
        sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 14:00:00Z])

      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 2.0
    end

    test "an agent left running with nobody prompting it spends nothing" do
      # The reason the allowance is denominated in turn hours: a sandbox
      # forgotten overnight is a Fountain cost, not a customer overage.
      user = insert_verified_user()
      sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 0.0

      # ...while the wall-clock number the provider invoice is checked against
      # still sees the whole day.
      assert %{"sprites" => 86_400} =
               SandboxUsage.for_user(user.id, @period_start, @period_end)
    end

    test "hours on the tenant's own runner do not count" do
      user = insert_verified_user()

      runner =
        sandbox_running(user, "runner", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(runner, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 15:00:00Z])

      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 0.0
    end

    test "platform providers are summed, the runner is left out of the same total" do
      user = insert_verified_user()

      sprites =
        sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      e2b = sandbox_running(user, "e2b", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      runner =
        sandbox_running(user, "runner", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(sprites, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])
      turn(e2b, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:30:00Z])
      turn(runner, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 20:00:00Z])

      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 1.5
    end

    test "a turn spanning the period boundary counts only the part inside it" do
      user = insert_verified_user()

      sandbox =
        sandbox_running(user, "sprites", ~U[2026-04-28 00:00:00Z], ~U[2026-05-02 00:00:00Z])

      turn(sandbox, user, ~U[2026-04-30 23:00:00Z], ~U[2026-05-01 01:00:00Z])

      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 1.0
    end

    test "one tenant's turns are not another's" do
      user = insert_verified_user()
      other = insert_verified_user()

      sandbox =
        sandbox_running(other, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(sandbox, other, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 14:00:00Z])

      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 0.0
    end

    test "defaults to the tenant's billing period" do
      user = insert_verified_user()

      sandbox =
        sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      # The default window is the current calendar month (ADR 0031), which
      # contains none of the turn above; the explicit period finds it.
      assert Billing.turn_hours_used(user) == 0.0
      assert Billing.turn_hours_used(user, period: {@period_start, @period_end}) == 1.0
    end
  end

  describe "busy_for_user/3" do
    test "reports turn seconds per provider, omitting providers with none" do
      user = insert_verified_user()

      sprites =
        sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      sandbox_running(user, "e2b", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])
      turn(sprites, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:30:00Z])

      assert SandboxUsage.busy_for_user(user.id, @period_start, @period_end) ==
               %{"sprites" => 1800}
    end
  end
end
