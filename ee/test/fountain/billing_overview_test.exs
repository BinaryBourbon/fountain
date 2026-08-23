defmodule Fountain.BillingOverviewTest do
  use Fountain.DataCase, async: true

  alias Fountain.Billing

  @now ~U[2026-08-15 12:00:00Z]

  defp set_status!(user, status, extra \\ []) do
    Repo.update!(Ecto.Changeset.change(user, [subscription_status: status] ++ extra))
  end

  defp set_plan!(user, plan), do: Repo.update!(Ecto.Changeset.change(user, plan: plan))

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
    test "each active account at its own plan's price; comped and past_due excluded" do
      set_plan!(set_status!(insert_verified_user(), "active"), "solo")
      set_plan!(set_status!(insert_verified_user(), "active"), "scale")
      set_plan!(set_status!(insert_verified_user(), "past_due"), "scale")
      set_plan!(set_status!(insert_verified_user(), "comped"), "scale")

      expected = Fountain.Plans.monthly_cents("solo") + Fountain.Plans.monthly_cents("scale")

      assert %{mrr_cents: ^expected} = Billing.overview_admin(now: @now)
    end

    test "the tile carries the per-plan split behind it" do
      set_plan!(set_status!(insert_verified_user(), "active"), "team")
      set_plan!(set_status!(insert_verified_user(), "active"), "team")

      assert %{mrr_by_plan: [%{plan: %{slug: "team"}, accounts: 2}]} =
               Billing.overview_admin(now: @now)
    end

    test "no active subscriptions is zero, not nil" do
      set_status!(insert_verified_user(), "trialing")

      # It used to be `nil` whenever `STRIPE_PRICE_MONTHLY_CENTS` was unset,
      # because there was no way to price an account without it. The catalog
      # holds every plan's price now, so an empty MRR is a fact rather than a
      # missing configuration.
      assert %{mrr_cents: 0} = Billing.overview_admin(now: @now)
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

  describe "overview_admin/1 — failed events (#501)" do
    defp fail_event!(event) do
      Billing.record_webhook_failure(event, :database_unavailable)
    end

    test "lists unresolved failures, most recently failed first" do
      fail_event!(%Stripe.Event{id: "evt_fail_a", type: "customer.subscription.updated"})
      fail_event!(%Stripe.Event{id: "evt_fail_b", type: "invoice.paid"})

      %{failed_events: failed} = Billing.overview_admin(now: @now)

      assert Enum.map(failed, & &1.event_id) |> Enum.sort() == ["evt_fail_a", "evt_fail_b"]
      assert [%{error: error, failure_count: 1} | _] = failed
      assert error =~ "database_unavailable"
    end

    test "a repeated failure is one row with a bumped count, not a row per retry" do
      event = %Stripe.Event{id: "evt_fail_retry", type: "customer.subscription.updated"}
      fail_event!(event)
      fail_event!(event)
      fail_event!(event)

      %{failed_events: failed} = Billing.overview_admin(now: @now)

      assert [%{event_id: "evt_fail_retry", failure_count: 3}] = failed
    end

    test "a resolved failure disappears; a new failure un-resolves it" do
      event = %Stripe.Event{id: "evt_fail_resolve", type: "customer.subscription.updated"}
      fail_event!(event)

      :ok = Billing.resolve_webhook_failure("evt_fail_resolve")
      assert %{failed_events: []} = Billing.overview_admin(now: @now)

      fail_event!(event)

      assert %{failed_events: [%{event_id: "evt_fail_resolve"}]} =
               Billing.overview_admin(now: @now)
    end

    test "an event with no id records nothing rather than raising" do
      assert :ok = Billing.record_webhook_failure(%Stripe.Event{id: nil, type: "x"}, :boom)
      assert :ok = Billing.resolve_webhook_failure(nil)
      assert %{failed_events: []} = Billing.overview_admin(now: @now)
    end
  end
end
