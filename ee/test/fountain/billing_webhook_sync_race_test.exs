defmodule Fountain.BillingWebhookSyncRaceTest do
  @moduledoc """
  Regression tests for #393: webhook sync evaluated its ownership and
  ordering guards on an unlocked read, so the #309 lockout was reachable as
  a race during a mid-trial upgrade — the deletion of the superseded trial
  subscription could read the user before the checkout's transaction
  committed, pass the guards, and land its cancellation after the checkout's
  write.

  The SQL Sandbox serializes everything onto one connection, so the
  interleaving itself cannot be reproduced here. These tests pin the three
  mechanisms that close it instead:

  1. the sync paths read the user row `FOR UPDATE` (asserted via query
     telemetry), so a concurrent sync blocks until the competing
     transaction commits and re-evaluates against the committed row;
  2. checkout adoption stamps `subscription_synced_at`, so the ordering
     guard defends the adoption against stragglers (pre-#393 it never
     participated and could not defend itself even in principle);
  3. the Stripe cancellation calls run before the claim transaction opens,
     which is what kept the DB transaction — and now the row lock — from
     being held across third-party HTTP.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Billing, Repo}
  alias Fountain.Accounts.User

  defp trialing_user_on(customer_id, sub_id) do
    user = insert_verified_user()
    {:ok, user} = Billing.attach_stripe_customer(user, customer_id)

    {:ok, user} =
      user
      |> User.billing_changeset(%{stripe_subscription_id: sub_id})
      |> Repo.update()

    user
  end

  defp checkout_event(id, customer, sub_id, user_id, created) do
    %Stripe.Event{
      id: id,
      type: "checkout.session.completed",
      created: created,
      data: %{object: %{customer: customer, subscription: sub_id, client_reference_id: user_id}}
    }
  end

  defp sub_event(id, type, customer, sub_id, status, created) do
    %Stripe.Event{
      id: id,
      type: type,
      created: created,
      data: %{object: %{id: sub_id, customer: customer, status: status, trial_end: nil}}
    }
  end

  defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()

  defp capture_locked_queries do
    test_pid = self()
    handler_id = "for-update-#{inspect(test_pid)}"

    :telemetry.attach(
      handler_id,
      [:fountain, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.query =~ "FOR UPDATE", do: send(test_pid, {:locked_query, meta.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "row lock (#393 mechanism 1)" do
    test "subscription lifecycle sync reads the user under FOR UPDATE" do
      capture_locked_queries()
      user = trialing_user_on("cus_lock_read", "sub_lr")

      {:ok, _} =
        Billing.handle_event(
          sub_event(
            "evt_lr",
            "customer.subscription.updated",
            "cus_lock_read",
            "sub_lr",
            "active",
            now_unix()
          )
        )

      assert_received {:locked_query, query}
      assert query =~ "users"
      assert Repo.reload(user).subscription_status == "active"
    end

    test "checkout sync reads the user under FOR UPDATE, via customer id and via client_reference_id" do
      capture_locked_queries()
      user = trialing_user_on("cus_lock_co", "sub_lc_old")

      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: [], has_more: false}} end)

      {:ok, _} =
        Billing.handle_event(
          checkout_event("evt_lc", "cus_lock_co", "sub_lc_new", user.id, now_unix())
        )

      assert_received {:locked_query, _}

      # A user with no customer link yet resolves through client_reference_id;
      # that read must be locked too.
      unlinked = insert_verified_user()

      {:ok, _} =
        Billing.handle_event(
          checkout_event("evt_lc2", "cus_lock_co2", "sub_lc2", unlinked.id, now_unix())
        )

      assert_received {:locked_query, _}
    end
  end

  describe "adoption watermark (#393 mechanism 2)" do
    test "checkout adoption stamps subscription_synced_at with the event timestamp" do
      user = trialing_user_on("cus_wm", "sub_wm_old")
      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: [], has_more: false}} end)

      t0 = now_unix()

      {:ok, updated} =
        Billing.handle_event(checkout_event("evt_wm", "cus_wm", "sub_wm_new", user.id, t0))

      assert updated.subscription_synced_at ==
               t0 |> DateTime.from_unix!() |> DateTime.truncate(:second)
    end

    test "an out-of-order event for the adopted subscription cannot move the account backwards" do
      user = trialing_user_on("cus_wm2", "sub_wm2_old")
      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: [], has_more: false}} end)

      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(checkout_event("evt_wm2", "cus_wm2", "sub_wm2_new", user.id, t0))

      # A straggler about the adopted subscription, created before the
      # checkout. Pre-#393 the adoption left subscription_synced_at
      # untouched, stale?/2 saw nil, and this cancelled a paying account.
      assert {:ok, :stale} =
               Billing.handle_event(
                 sub_event(
                   "evt_wm2_straggler",
                   "customer.subscription.deleted",
                   "cus_wm2",
                   "sub_wm2_new",
                   "canceled",
                   t0 - 60
                 )
               )

      reloaded = Repo.reload(user)
      assert reloaded.subscription_status == "active"
      assert reloaded.stripe_subscription_id == "sub_wm2_new"
    end

    test "the adoption never moves an existing watermark backwards" do
      user = trialing_user_on("cus_wm3", "sub_wm3_old")
      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: [], has_more: false}} end)

      t0 = now_unix()

      # A lifecycle event stamps the watermark at t0...
      {:ok, _} =
        Billing.handle_event(
          sub_event(
            "evt_wm3_a",
            "customer.subscription.updated",
            "cus_wm3",
            "sub_wm3_old",
            "trialing",
            t0
          )
        )

      # ...then a checkout whose event timestamp is older must keep it at t0.
      {:ok, updated} =
        Billing.handle_event(
          checkout_event("evt_wm3_b", "cus_wm3", "sub_wm3_new", user.id, t0 - 120)
        )

      assert updated.subscription_synced_at ==
               t0 |> DateTime.from_unix!() |> DateTime.truncate(:second)
    end
  end

  describe "Stripe calls outside the transaction (#393 mechanism 3)" do
    test "checkout cancellations run before the claim transaction opens" do
      user = trialing_user_on("cus_notxn", "sub_notxn_old")
      test_pid = self()

      # Mimic stubs execute in the calling process, so Repo.in_transaction?
      # here reports the transaction state of the sync path itself.
      expect(Stripe.Subscription, :list, fn _ ->
        send(test_pid, {:list_in_txn, Repo.in_transaction?()})

        {:ok,
         %{data: [%Stripe.Subscription{id: "sub_notxn_old", status: "trialing"}], has_more: false}}
      end)

      expect(Stripe.Subscription, :cancel, fn id ->
        send(test_pid, {:cancel_in_txn, Repo.in_transaction?()})
        {:ok, %Stripe.Subscription{id: id, status: "canceled"}}
      end)

      event = checkout_event("evt_notxn", "cus_notxn", "sub_notxn_new", user.id, now_unix())

      assert {:ok, updated} = Billing.handle_event(event)
      assert updated.stripe_subscription_id == "sub_notxn_new"
      assert updated.subscription_status == "active"

      assert_received {:list_in_txn, false}
      assert_received {:cancel_in_txn, false}

      # A redelivery after adoption is a duplicate and must not call Stripe
      # again — the expect/3 counts above (one call each) enforce that.
      assert {:ok, :duplicate} = Billing.handle_event(event)
    end

    test "a failed cancellation still leaves the event unclaimed for redelivery" do
      user = trialing_user_on("cus_fail", "sub_fail_old")

      stub(Stripe.Subscription, :list, fn _ -> {:error, :stripe_down} end)

      event = checkout_event("evt_fail", "cus_fail", "sub_fail_new", user.id, now_unix())
      assert {:error, :stripe_down} = Billing.handle_event(event)

      reloaded = Repo.reload(user)
      assert reloaded.stripe_subscription_id == "sub_fail_old"

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok,
         %{data: [%Stripe.Subscription{id: "sub_fail_old", status: "trialing"}], has_more: false}}
      end)

      stub(Stripe.Subscription, :cancel, fn id ->
        {:ok, %Stripe.Subscription{id: id, status: "canceled"}}
      end)

      assert {:ok, updated} = Billing.handle_event(event)
      assert updated.stripe_subscription_id == "sub_fail_new"
    end
  end
end
