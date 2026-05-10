defmodule Fountain.BillingTest do
  use Fountain.DataCase, async: true

  alias Fountain.Billing
  alias Fountain.Billing.UsageEvent
  alias Fountain.Repo

  describe "assert_active!/1" do
    test "returns :ok for trialing status" do
      user = user_with_status("trialing")
      assert :ok = Billing.assert_active!(user)
    end

    test "returns :ok for active status" do
      user = user_with_status("active")
      assert :ok = Billing.assert_active!(user)
    end

    test "raises SubscriptionRequiredError for past_due status" do
      user = user_with_status("past_due")

      assert_raise Billing.SubscriptionRequiredError, fn ->
        Billing.assert_active!(user)
      end
    end

    test "raises SubscriptionRequiredError for canceled status" do
      user = user_with_status("canceled")

      assert_raise Billing.SubscriptionRequiredError, fn ->
        Billing.assert_active!(user)
      end
    end
  end

  describe "usage_summary/3" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "returns zeros when no events exist", %{user: user} do
      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 0
      assert summary.turns == 0
      assert summary.sandbox_minutes == 0.0
    end

    test "counts sandbox_provisioned events as conversations", %{user: user} do
      insert_event(user, "sandbox_provisioned", ~U[2026-05-10 12:00:00Z])
      insert_event(user, "sandbox_provisioned", ~U[2026-05-15 09:00:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 2
      assert summary.turns == 0
    end

    test "counts turn_started events as turns", %{user: user} do
      insert_event(user, "turn_started", ~U[2026-05-10 12:00:00Z])
      insert_event(user, "turn_started", ~U[2026-05-10 12:05:00Z])
      insert_event(user, "turn_started", ~U[2026-05-10 12:10:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.turns == 3
    end

    test "sums duration_ms from sandbox_terminated events into sandbox_minutes", %{user: user} do
      # 60_000 ms = 1 min, 120_000 ms = 2 min → total 3.0 minutes
      insert_event(user, "sandbox_terminated", ~U[2026-05-10 12:00:00Z], %{"duration_ms" => 60_000})
      insert_event(user, "sandbox_terminated", ~U[2026-05-10 12:30:00Z], %{"duration_ms" => 120_000})

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 3.0
    end

    test "excludes events outside the period", %{user: user} do
      # One second before period start — excluded
      insert_event(user, "turn_started", ~U[2026-04-30 23:59:59Z])
      # Exactly at period_end — excluded (query uses `< ^period_end`)
      insert_event(user, "sandbox_provisioned", ~U[2026-06-01 00:00:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 0
      assert summary.turns == 0
      assert summary.sandbox_minutes == 0.0
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp user_with_status(status) do
    user = insert_verified_user()
    Ecto.Changeset.change(user, subscription_status: status) |> Repo.update!()
  end

  defp insert_event(user, event_type, inserted_at, metadata \\ %{}) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      user_id: user.id,
      event_type: event_type,
      inserted_at: inserted_at,
      metadata: metadata
    })
    |> Repo.insert!()
  end
end
