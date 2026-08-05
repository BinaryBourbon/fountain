defmodule Fountain.BillingOverviewTest do
  use Fountain.DataCase, async: true

  alias Fountain.Billing

  @now ~U[2026-08-15 12:00:00Z]

  defp set_status!(user, status, extra \\ []) do
    Repo.update!(Ecto.Changeset.change(user, [subscription_status: status] ++ extra))
  end

  defp insert_stripe_event!(id, type, inserted_at) do
    Repo.insert_all("stripe_events", [
      %{id: id, type: type, inserted_at: DateTime.truncate(inserted_at, :second)}
    ])
  end

  describe "overview_admin/1 — status counts" do
    test "groups users by subscription status" do
      _trialing = insert_verified_user()
      set_status!(insert_verified_user(), "active")
      set_status!(insert_verified_user(), "active")
      set_status!(insert_verified_user(), "canceled")

      %{status_counts: counts} = Billing.overview_admin(now: @now)

      assert counts["trialing"] == 1
      assert counts["active"] == 2
      assert counts["canceled"] == 1
      refute Map.has_key?(counts, "comped")
    end
  end

  describe "overview_admin/1 — trials ending in 7 days" do
    test "counts only trialing users inside the window" do
      in_window = insert_verified_user()
      set_status!(in_window, "trialing", trial_ends_at: ~U[2026-08-20 00:00:00Z])

      too_far = insert_verified_user()
      set_status!(too_far, "trialing", trial_ends_at: ~U[2026-08-25 00:00:00Z])

      already_over = insert_verified_user()
      set_status!(already_over, "trialing", trial_ends_at: ~U[2026-08-14 00:00:00Z])

      # Right status window, wrong status: an active user's stale trial date
      wrong_status = insert_verified_user()
      set_status!(wrong_status, "active", trial_ends_at: ~U[2026-08-20 00:00:00Z])

      assert %{trials_ending_7d: 1} = Billing.overview_admin(now: @now)
    end
  end

  describe "overview_admin/1 — conversions this month" do
    test "counts checkout.session.completed since the start of the month" do
      insert_stripe_event!(
        "evt_this_month",
        "checkout.session.completed",
        ~U[2026-08-03 09:00:00Z]
      )

      insert_stripe_event!(
        "evt_last_month",
        "checkout.session.completed",
        ~U[2026-07-31 23:00:00Z]
      )

      insert_stripe_event!(
        "evt_other_type",
        "customer.subscription.updated",
        ~U[2026-08-04 09:00:00Z]
      )

      assert %{conversions_this_month: 1} = Billing.overview_admin(now: @now)
    end
  end

  describe "overview_admin/1 — MRR" do
    test "active count times the configured price; comped and past_due excluded" do
      set_status!(insert_verified_user(), "active")
      set_status!(insert_verified_user(), "active")
      set_status!(insert_verified_user(), "past_due")
      set_status!(insert_verified_user(), "comped")

      assert %{mrr_cents: 5800} = Billing.overview_admin(now: @now, price_cents: 2900)
    end

    test "nil when no price is configured — no fabricated number" do
      set_status!(insert_verified_user(), "active")

      assert %{mrr_cents: nil} = Billing.overview_admin(now: @now, price_cents: nil)
    end
  end

  describe "overview_admin/1 — recent events" do
    test "newest first, capped at the limit" do
      for i <- 1..4 do
        insert_stripe_event!(
          "evt_#{i}",
          "customer.subscription.updated",
          DateTime.add(~U[2026-08-10 00:00:00Z], i, :hour)
        )
      end

      %{recent_events: events} = Billing.overview_admin(now: @now, event_limit: 3)

      assert Enum.map(events, & &1.id) == ["evt_4", "evt_3", "evt_2"]
      assert [%{type: "customer.subscription.updated"} | _] = events
      refute is_nil(hd(events).inserted_at)
    end
  end
end
