defmodule Fountain.Workers.StripeCustomerSyncTest do
  @moduledoc """
  Durable Stripe customer creation.

  This used to be a bare `Task.async` with no `await`, launched from the
  email-verification request. The task was linked to the request process, so it
  could be killed when that finished, and a Stripe error had no retry and no log
  — it just left an account with a nil `stripe_customer_id`. 153 of 190
  production accounts are in that state, and until #212 those accounts hit a
  Checkout flow that charged the card without activating the account.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Repo
  alias Fountain.Accounts.User
  alias Fountain.Workers.StripeCustomerSync

  describe "perform/1" do
    test "creates the customer" do
      user = insert_verified_user()
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_job"}} end)

      assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})
      assert Repo.get(User, user.id).stripe_customer_id == "cus_job"
    end

    test "is idempotent — a rerun does not mint a second customer" do
      user = insert_verified_user()
      {:ok, _} = Fountain.Billing.attach_stripe_customer(user, "cus_existing")

      # No stub: a call to Stripe would fail the test.
      assert :ok = perform_job(StripeCustomerSync, %{user_id: user.id})
      assert Repo.get(User, user.id).stripe_customer_id == "cus_existing"
    end

    test "returns an error so Oban retries, rather than losing the work" do
      # The old Task swallowed this entirely.
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _ ->
        {:error, %Stripe.Error{source: :stripe, code: :api_error, message: "down"}}
      end)

      assert {:error, _} = perform_job(StripeCustomerSync, %{user_id: user.id})
      refute Repo.get(User, user.id).stripe_customer_id
    end

    test "a deleted user is not retried forever" do
      # Nothing will bring the account back, so this is :ok rather than an error.
      assert :ok = perform_job(StripeCustomerSync, %{user_id: Ecto.UUID.generate()})
    end
  end

  describe "enqueue/1" do
    test "inserts a job for the user" do
      user = insert_verified_user()

      assert {:ok, _job} = StripeCustomerSync.enqueue(user)
      assert_enqueued(worker: StripeCustomerSync, args: %{user_id: user.id})
    end

    test "accepts a bare id" do
      user = insert_verified_user()

      assert {:ok, _job} = StripeCustomerSync.enqueue(user.id)
      assert_enqueued(worker: StripeCustomerSync, args: %{user_id: user.id})
    end

    test "runs on the billing queue with retries" do
      assert StripeCustomerSync.__opts__()[:queue] == :billing
      assert StripeCustomerSync.__opts__()[:max_attempts] == 5
    end
  end
end
