defmodule Fountain.TrialExpiryTest do
  @moduledoc """
  Trials that actually end.

  Only a Stripe Customer was created at signup — never a Subscription — so
  Stripe had no object to run a trial against, would never emit a lifecycle
  webhook for one, and nothing anywhere moved an account off `trialing` when the
  date passed. `trial_ends_at` was written locally and read only to render a
  countdown. Production: 196 trialing accounts, 1 paying.

  Two independent mechanisms now, and the second exists because the first is the
  one that failed. Stripe drives the lifecycle, and the gate also checks the
  clock, so an undelivered webhook delays revenue rather than forfeiting it.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.Billing

  setup :set_mimic_global

  setup do
    previous = Application.get_env(:fountain, :stripe_price_id)
    Application.put_env(:fountain, :stripe_price_id, "price_test")
    on_exit(fn -> Application.put_env(:fountain, :stripe_price_id, previous) end)
    :ok
  end

  defp trialing_user(trial_ends_at) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> User.billing_changeset(%{
        subscription_status: "trialing",
        trial_ends_at: trial_ends_at
      })
      |> Repo.update()

    user
  end

  defp ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

  defp ahead(days),
    do: DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)

  describe "the gate" do
    test "a trial with time left is active" do
      assert :ok = Billing.check_active(trialing_user(ahead(3)))
    end

    test "an elapsed trial is not" do
      # The behaviour the whole issue is about.
      assert {:error, :subscription_required} = Billing.check_active(trialing_user(ago(1)))
    end

    test "expiry does not wait for a webhook" do
      # Nothing has touched subscription_status — it is still "trialing", which
      # used to be enough on its own. Stripe emitting the status change is the
      # mechanism that never worked, so the gate must not depend on it.
      user = trialing_user(ago(1))
      assert user.subscription_status == "trialing"
      assert {:error, :subscription_required} = Billing.check_active(user)
    end

    test "a nil trial end is no expiry only for pre-backfill accounts" do
      # 159 production accounts were in this state, from before a trial end was
      # recorded at all; they were backfilled on 2026-08-02. Accounts older
      # than the backfill keep the lenient reading in case any reappear.
      legacy =
        Repo.update!(
          Ecto.Changeset.change(trialing_user(nil), inserted_at: ~U[2026-07-01 00:00:00Z])
        )

      assert :ok = Billing.check_active(legacy)
    end

    test "a post-backfill account with a nil trial end fails closed" do
      # Registration stamps trial_ends_at on every account, so nil on a new
      # account means a stalled sync or data drift. The open-ended branch here
      # turned every such account into a free one (#314); support has
      # extend_trial to reopen a legitimate casualty.
      assert {:error, :subscription_required} = Billing.check_active(trialing_user(nil))
    end

    test "an active subscription is unaffected by the trial clock" do
      user = insert_verified_user()

      {:ok, user} =
        user
        |> User.billing_changeset(%{subscription_status: "active", trial_ends_at: ago(30)})
        |> Repo.update()

      assert :ok = Billing.check_active(user)
    end

    test "a cancelled account stays refused" do
      user = insert_verified_user()

      {:ok, user} =
        user
        |> User.billing_changeset(%{subscription_status: "canceled", trial_ends_at: ahead(10)})
        |> Repo.update()

      assert {:error, :subscription_required} = Billing.check_active(user)
    end

    test "BILLING_ENABLED=false still bypasses everything" do
      # A self-hosted instance has no Stripe and no trial to expire.
      user = trialing_user(ago(100))
      previous = Application.get_env(:fountain, :billing_enabled)
      Application.put_env(:fountain, :billing_enabled, false)

      try do
        assert :ok = Billing.check_active(user)
      after
        Application.put_env(:fountain, :billing_enabled, previous)
      end
    end
  end

  describe "starting a trial" do
    test "creates a real Stripe subscription, not just a customer" do
      user = insert_verified_user()
      test = self()

      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_new"}} end)

      stub(Stripe.Subscription, :create, fn params ->
        send(test, {:subscription_params, params})
        {:ok, %{id: "sub_new", status: "trialing", trial_end: DateTime.to_unix(ahead(14))}}
      end)

      assert {:ok, user} = Billing.create_stripe_customer(user)
      assert {:ok, updated} = Billing.start_trial_subscription(user)

      assert_received {:subscription_params, params}
      assert params.customer == "cus_new"
      assert params.trial_period_days == 14
      assert [%{price: "price_test"}] = params.items

      assert updated.stripe_customer_id == "cus_new"
      assert updated.subscription_status == "trialing"
      assert updated.trial_ends_at
    end

    test "cancels rather than invoicing when the trial ends with no card" do
      # create_invoice would raise an unpaid invoice and start Stripe's dunning
      # emails — chasing payment from someone who never entered a card. Cancel
      # closes the gate just as effectively and says nothing untrue.
      user = insert_verified_user()
      test = self()

      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_x"}} end)

      stub(Stripe.Subscription, :create, fn params ->
        send(test, {:params, params})
        {:ok, %{id: "sub_x", status: "trialing", trial_end: DateTime.to_unix(ahead(14))}}
      end)

      {:ok, user} = Billing.create_stripe_customer(user)
      Billing.start_trial_subscription(user)

      assert_received {:params, params}
      assert params.trial_settings.end_behavior.missing_payment_method == :cancel
    end

    test "trial_ends_at comes from Stripe, not from local arithmetic" do
      # So the database agrees with the thing that will actually do the charging.
      user = insert_verified_user()
      stripe_end = ahead(9)

      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_y"}} end)

      stub(Stripe.Subscription, :create, fn _ ->
        {:ok, %{id: "sub_y", status: "trialing", trial_end: DateTime.to_unix(stripe_end)}}
      end)

      assert {:ok, user} = Billing.create_stripe_customer(user)
      assert {:ok, updated} = Billing.start_trial_subscription(user)
      assert DateTime.compare(updated.trial_ends_at, stripe_end) == :eq
    end

    test "the customer is saved even if the subscription call fails" do
      # Two separate API calls. Losing the customer id on a subscription failure
      # would make the Oban retry mint a second Stripe Customer.
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_partial"}} end)
      stub(Stripe.Subscription, :create, fn _ -> {:error, :stripe_down} end)

      assert {:ok, user} = Billing.create_stripe_customer(user)
      assert {:error, :stripe_down} = Billing.start_trial_subscription(user)
      assert Repo.reload(user).stripe_customer_id == "cus_partial"
    end

    test "no price configured falls back to a local trial instead of failing" do
      # A self-hosted instance has no STRIPE_PRICE_ID. Erroring here would fail
      # the signup job forever on an instance that will never bill anyone.
      Application.put_env(:fountain, :stripe_price_id, nil)
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_selfhost"}} end)
      reject(&Stripe.Subscription.create/1)

      assert {:ok, user} = Billing.create_stripe_customer(user)
      assert {:ok, updated} = Billing.start_trial_subscription(user)
      assert updated.trial_ends_at
    end

    test "the Checkout path does not open a trial subscription" do
      # create_stripe_customer/1 is shared with Checkout, where the user is
      # about to buy. Opening a trialing subscription moments before a paid one
      # would be wrong, so starting the trial is a separate call.
      user = insert_verified_user()
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_checkout"}} end)
      reject(&Stripe.Subscription.create/1)

      assert {:ok, _} = Billing.create_stripe_customer(user)
    end
  end
end
