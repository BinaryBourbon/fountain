defmodule Fountain.TrialSubscriptionIdempotencyTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Billing, Repo}
  alias Fountain.Accounts.User

  # Regression tests for #400: trial-subscription creation wrote Stripe's
  # status straight through (the changeset rejects incomplete/unpaid/paused,
  # unlike the webhook path, which coerces them) and re-entered on every Oban
  # retry because the worker's guard checks a field the failed write never
  # set — each retry minting another trialing subscription.

  setup do
    Application.put_env(:fountain, :stripe_price_id, "price_trial_test")
    on_exit(fn -> Application.delete_env(:fountain, :stripe_price_id) end)

    user = insert_verified_user()
    {:ok, user} = Billing.attach_stripe_customer(user, "cus_trial_idem")
    {:ok, user: user}
  end

  test "a status outside the changeset's set is coerced, not rejected", %{user: user} do
    # Pre-#400 this returned {:error, %Ecto.Changeset{}} — the failed local
    # write that made Oban retry and duplicate the subscription.
    stub(Stripe.Subscription, :create, fn _params, _opts ->
      {:ok, %Stripe.Subscription{id: "sub_trial_inc", status: "incomplete", trial_end: nil}}
    end)

    assert {:ok, %User{} = updated} = Billing.start_trial_subscription(user)
    assert updated.stripe_subscription_id == "sub_trial_inc"
    # incomplete coerces to past_due, exactly as the webhook path does.
    assert updated.subscription_status == "past_due"
    assert Repo.reload(user).stripe_subscription_id == "sub_trial_inc"
  end

  test "creation sends a stable per-user idempotency key", %{user: user} do
    test_pid = self()

    stub(Stripe.Subscription, :create, fn _params, opts ->
      send(test_pid, {:idempotency_key, get_in(opts, [:headers, "Idempotency-Key"])})
      {:ok, %Stripe.Subscription{id: "sub_trial_ok", status: "trialing", trial_end: nil}}
    end)

    {:ok, _} = Billing.start_trial_subscription(user)

    # The retry shape: the local write failed, the worker re-enters, and the
    # SAME key must reach Stripe so it returns the original subscription
    # rather than minting a second one.
    {:ok, user} =
      Repo.reload(user) |> User.billing_changeset(%{stripe_subscription_id: nil}) |> Repo.update()

    {:ok, _} = Billing.start_trial_subscription(user)

    assert_received {:idempotency_key, key1}
    assert_received {:idempotency_key, key2}
    assert is_binary(key1) and key1 != ""
    assert key1 == key2
    assert key1 =~ user.id
  end
end
