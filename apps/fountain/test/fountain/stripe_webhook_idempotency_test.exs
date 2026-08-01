defmodule Fountain.StripeWebhookIdempotencyTest do
  @moduledoc """
  Replay and ordering protection for Stripe webhooks.

  Stripe retries a failed delivery for up to three days and makes no ordering
  promise. Without a record of what has been applied, both directions corrupt
  state: a replayed `updated{active}` landing after `.deleted` reactivates a
  cancelled account, and a stale `past_due` landing after recovery locks out a
  paying one.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Billing
  alias Fountain.Repo

  defp user_with_customer(customer_id) do
    user = insert_verified_user()
    {:ok, user} = Billing.attach_stripe_customer(user, customer_id)
    user
  end

  defp sub_event(id, type, customer, status, created) do
    %Stripe.Event{
      id: id,
      type: type,
      created: created,
      data: %{object: %{customer: customer, status: status, trial_end: nil}}
    }
  end

  defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()

  describe "replay protection" do
    test "the same event id is applied once" do
      user = user_with_customer("cus_replay")

      event =
        sub_event("evt_1", "customer.subscription.created", "cus_replay", "active", now_unix())

      assert {:ok, updated} = Billing.handle_event(event)
      assert updated.subscription_status == "active"

      assert {:ok, :duplicate} = Billing.handle_event(event)
      assert Repo.reload(user).subscription_status == "active"
    end

    test "a redelivered activation cannot resurrect a cancelled account" do
      # The scenario that motivates this: Stripe retries an older event after a
      # newer one has already been applied.
      user = user_with_customer("cus_zombie")
      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_active", "customer.subscription.updated", "cus_zombie", "active", t0)
        )

      {:ok, _} =
        Billing.handle_event(
          sub_event(
            "evt_gone",
            "customer.subscription.deleted",
            "cus_zombie",
            "canceled",
            t0 + 10
          )
        )

      assert Repo.reload(user).subscription_status == "canceled"

      # Stripe redelivers the activation.
      assert {:ok, :duplicate} =
               Billing.handle_event(
                 sub_event(
                   "evt_active",
                   "customer.subscription.updated",
                   "cus_zombie",
                   "active",
                   t0
                 )
               )

      assert Repo.reload(user).subscription_status == "canceled"
    end

    test "distinct event ids are each applied" do
      user = user_with_customer("cus_two")
      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_a", "customer.subscription.updated", "cus_two", "active", t0)
        )

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_b", "customer.subscription.updated", "cus_two", "past_due", t0 + 5)
        )

      assert Repo.reload(user).subscription_status == "past_due"
    end
  end

  describe "ordering guard" do
    test "an out-of-order older event is ignored" do
      # Same account, different event ids, delivered newest-first.
      user = user_with_customer("cus_order")
      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_new", "customer.subscription.deleted", "cus_order", "canceled", t0 + 60)
        )

      assert {:ok, :stale} =
               Billing.handle_event(
                 sub_event("evt_old", "customer.subscription.updated", "cus_order", "active", t0)
               )

      assert Repo.reload(user).subscription_status == "canceled"
    end

    test "a stale past_due cannot re-lock a recovered account" do
      user = user_with_customer("cus_recover")
      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(
          sub_event(
            "evt_recovered",
            "customer.subscription.updated",
            "cus_recover",
            "active",
            t0 + 60
          )
        )

      assert {:ok, :stale} =
               Billing.handle_event(
                 sub_event(
                   "evt_late",
                   "customer.subscription.updated",
                   "cus_recover",
                   "past_due",
                   t0
                 )
               )

      assert Repo.reload(user).subscription_status == "active"
    end

    test "a newer event still applies" do
      user = user_with_customer("cus_fwd")
      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_first", "customer.subscription.updated", "cus_fwd", "active", t0)
        )

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_second", "customer.subscription.deleted", "cus_fwd", "canceled", t0 + 30)
        )

      assert Repo.reload(user).subscription_status == "canceled"
    end

    test "an event with no timestamp is treated as fresh rather than dropped" do
      user = user_with_customer("cus_nots")

      {:ok, _} =
        Billing.handle_event(
          sub_event("evt_ts", "customer.subscription.updated", "cus_nots", "active", now_unix())
        )

      assert {:ok, updated} =
               Billing.handle_event(
                 sub_event(
                   "evt_nots",
                   "customer.subscription.updated",
                   "cus_nots",
                   "past_due",
                   nil
                 )
               )

      assert updated.subscription_status == "past_due"
      assert Repo.reload(user).subscription_status == "past_due"
    end
  end

  describe "unrelated events" do
    test "an unhandled type is claimed but ignored" do
      event = %Stripe.Event{
        id: "evt_other",
        type: "invoice.paid",
        created: now_unix(),
        data: %{object: %{}}
      }

      assert {:ok, :ignored} = Billing.handle_event(event)
      assert {:ok, :duplicate} = Billing.handle_event(event)
    end

    test "an event without an id still works, for hand-built events" do
      user = user_with_customer("cus_noid")

      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_noid", status: "active", trial_end: nil}}
      }

      assert {:ok, updated} = Billing.handle_event(event)
      assert updated.id == user.id
    end
  end
end
