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
  alias Fountain.Plans

  # A period wholly in the past, so `attribution/3`'s ceiling is the period end
  # rather than the wall clock and every expected figure is exact.
  @period_start ~U[2026-05-01 00:00:00Z]
  @period_end ~U[2026-06-01 00:00:00Z]

  defp with_period(user, period_start, period_end) do
    {:ok, user} =
      user
      |> Fountain.Accounts.User.billing_changeset(%{
        current_period_start: period_start,
        current_period_end: period_end
      })
      |> Repo.update()

    user
  end

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
    test "uses the Stripe period when one is stored and it contains now" do
      user =
        insert_verified_user()
        |> with_period(~U[2026-05-20 00:00:00Z], ~U[2026-06-20 00:00:00Z])

      assert %{
               start: ~U[2026-05-20 00:00:00Z],
               end: ~U[2026-06-20 00:00:00Z],
               source: :subscription
             } = Billing.billing_period(user, ~U[2026-06-01 12:00:00Z])
    end

    test "the mid-month subscriber's window is theirs, not the calendar's" do
      # The case the whole column exists for: subscribe on the 20th and every
      # allowance boundary lines up with the invoice instead of the 1st.
      user =
        insert_verified_user()
        |> with_period(~U[2026-05-20 00:00:00Z], ~U[2026-06-20 00:00:00Z])

      period = Billing.billing_period(user, ~U[2026-06-05 00:00:00Z])

      assert period.start.day == 20
      refute period.start.day == 1
    end

    test "falls back to the calendar month, and says so, with no period stored" do
      user = insert_verified_user()

      period = Billing.billing_period(user, ~U[2026-06-05 00:00:00Z])

      assert period.source == :calendar_month
      assert period.start.day == 1
    end

    test "a half-synced period is not a period" do
      # An end with no start is exactly the state every existing subscription
      # was in the moment the column shipped. Deriving the start from it is
      # what the issue warned against, so it falls back instead.
      user = insert_verified_user() |> with_period(nil, ~U[2026-06-20 00:00:00Z])

      assert Billing.billing_period(user, ~U[2026-06-05 00:00:00Z]).source == :calendar_month
    end

    test "a period that has already ended falls back rather than reporting a stale window" do
      # A cancelled subscription's final period, or the seconds between a
      # renewal and the webhook reporting the new one.
      user =
        insert_verified_user()
        |> with_period(~U[2026-01-20 00:00:00Z], ~U[2026-02-20 00:00:00Z])

      assert Billing.billing_period(user, ~U[2026-06-05 00:00:00Z]).source == :calendar_month
    end

    test "a period that has not started yet falls back too" do
      user =
        insert_verified_user()
        |> with_period(~U[2026-09-20 00:00:00Z], ~U[2026-10-20 00:00:00Z])

      assert Billing.billing_period(user, ~U[2026-06-05 00:00:00Z]).source == :calendar_month
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
      user =
        insert_verified_user()
        |> with_period(@period_start, @period_end)

      sandbox =
        sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      # The stored period has ended, so this falls back to the current calendar
      # month — which contains none of the turn above. The point of the
      # assertion is that the default window is *derived*, not hardcoded.
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

  describe "turn_hour_allowance/2" do
    test "reports used against the plan's included hours" do
      user = insert_active_user(plan: "solo")

      sandbox =
        sandbox_running(user, "sprites", ~U[2026-05-10 00:00:00Z], ~U[2026-05-11 00:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 00:00:00Z], ~U[2026-05-10 04:00:00Z])

      allowance =
        Billing.turn_hour_allowance(user,
          period: %{start: @period_start, end: @period_end, source: :subscription}
        )

      assert allowance.used == 4.0
      assert allowance.included == Plans.included_turn_hours("solo")
      assert allowance.remaining == Plans.included_turn_hours("solo") - 4.0
      refute allowance.over?
    end

    test "remaining never goes negative, and over? is what says so" do
      user = insert_active_user(plan: "solo")

      # 101 hours against Solo's allowance: comfortably over it.
      sandbox =
        sandbox_running(user, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-10 00:00:00Z])

      turn(sandbox, user, ~U[2026-05-02 00:00:00Z], ~U[2026-05-06 05:00:00Z])

      allowance =
        Billing.turn_hour_allowance(user,
          period: %{start: @period_start, end: @period_end, source: :subscription}
        )

      assert allowance.used == 101.0
      assert allowance.remaining == 0.0
      assert allowance.over?
    end

    test "carries the period and its source through untouched" do
      # Every surface labels the fallback from this, so it must survive the
      # trip rather than being recomputed per caller.
      user = insert_verified_user()

      allowance = Billing.turn_hour_allowance(user)

      assert allowance.period.source == :calendar_month
      assert allowance.period.start.day == 1
    end

    test "a bigger plan carries proportionally more" do
      solo = insert_active_user(plan: "solo")
      scale = insert_active_user(plan: "scale")

      assert Billing.turn_hour_allowance(scale).included >
               Billing.turn_hour_allowance(solo).included
    end
  end
end
