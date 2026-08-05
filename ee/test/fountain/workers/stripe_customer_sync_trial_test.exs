defmodule Fountain.Workers.StripeCustomerSyncTrialTest do
  @moduledoc """
  The signup path must end with a real Stripe trial subscription (#351).

  Registration stamps `trial_ends_at` on every account, so the worker's old
  `is_nil(trial_ends_at)` guard was permanently false and
  `start_trial_subscription/1` was unreachable — no signup ever got a Stripe
  subscription, and everything Stripe-driven (trial_will_end, the deletion at
  trial end, the lifecycle emails hanging off both) was dead for post-#244
  accounts. Each half had passing tests; these are the
  registration → verification → worker tests that exercise them together.

  `async: false` because these set `:stripe_price_id`, which is global.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.Repo
  alias Fountain.Workers.StripeCustomerSync

  setup do
    previous = Application.get_env(:fountain, :stripe_price_id)
    Application.put_env(:fountain, :stripe_price_id, "price_test")
    on_exit(fn -> Application.put_env(:fountain, :stripe_price_id, previous) end)
    :ok
  end

  test "the verified signup path ends with a real Stripe subscription" do
    user = insert_verified_user()
    assert user.trial_ends_at
    test = self()

    stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_e2e"}} end)

    stub(Stripe.Subscription, :create, fn params, _opts ->
      send(test, {:sub_params, params})
      {:ok, %{id: "sub_e2e", status: "trialing", trial_end: params.trial_end}}
    end)

    assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})

    # Anchored to the registration-stamped end, not a fresh 14-day window that
    # would restart the clock at verification time.
    assert_received {:sub_params, params}
    assert params.trial_end == DateTime.to_unix(user.trial_ends_at)

    reloaded = Repo.get(User, user.id)
    assert reloaded.stripe_subscription_id == "sub_e2e"
    assert reloaded.subscription_status == "trialing"
  end

  test "a user with a subscription of record is left alone" do
    user = insert_verified_user()
    {:ok, user} = Fountain.Billing.attach_stripe_customer(user, "cus_has_sub")

    {:ok, _} =
      user
      |> User.billing_changeset(%{stripe_subscription_id: "sub_already"})
      |> Repo.update()

    # No Subscription.create stub: a call would fail the test.
    assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})
    assert Repo.get(User, user.id).stripe_subscription_id == "sub_already"
  end

  test "an expired local trial does not open a live subscription" do
    user = insert_verified_user()

    {:ok, _} =
      user
      |> User.billing_changeset(%{
        trial_ends_at: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      })
      |> Repo.update()

    stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_late"}} end)
    # Both arities: billing calls create/2 — a /1-only reject watches an
    # arity nothing calls, and the real call would fall through to live
    # Stripe instead of tripping the tripwire.
    reject(&Stripe.Subscription.create/1)
    reject(&Stripe.Subscription.create/2)

    assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})
    assert Repo.get(User, user.id).stripe_subscription_id == nil
  end

  test "a rerun on a priceless instance cannot extend the local trial" do
    # The worker re-runs on every OAuth login; without the standing-date guard
    # each one re-stamped trial_ends_at to now+14d.
    Application.put_env(:fountain, :stripe_price_id, nil)
    user = insert_verified_user()
    original_end = user.trial_ends_at

    stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_sh"}} end)

    assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})
    assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})

    assert Repo.get(User, user.id).trial_ends_at == original_end
  end
end
