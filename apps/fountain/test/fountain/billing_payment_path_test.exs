defmodule Fountain.BillingPaymentPathTest do
  @moduledoc """
  The path from "user clicks Upgrade" to "account is active".

  It had a hole big enough to take money through. When a user had no
  `stripe_customer_id`, Checkout was opened with `customer_email`, so Stripe
  minted its own Customer whose id we never learned. The resulting
  `customer.subscription.created` webhook then matched no user, the controller
  logged it and answered 200, and the card was charged against an account that
  stayed unactivated. Roughly 80% of accounts had no customer id, so this was
  the common case rather than an edge.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Accounts, Billing, Repo}
  alias Fountain.Accounts.User

  describe "ensure_stripe_customer/1" do
    test "creates a customer when the user has none" do
      user = insert_verified_user()
      refute user.stripe_customer_id

      expect(Stripe.Customer, :create, fn %{email: email} ->
        assert email == user.email
        {:ok, %Stripe.Customer{id: "cus_new123"}}
      end)

      assert {:ok, updated} = Billing.ensure_stripe_customer(user)
      assert updated.stripe_customer_id == "cus_new123"
      assert Repo.get(User, user.id).stripe_customer_id == "cus_new123"
    end

    test "reuses an existing customer without calling Stripe" do
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_existing")

      # No expect/3 on Stripe.Customer — a call would fail the test.
      assert {:ok, same} = Billing.ensure_stripe_customer(user)
      assert same.stripe_customer_id == "cus_existing"
    end

    test "sets a trial end date alongside the customer" do
      user = insert_verified_user()
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_t"}} end)

      assert {:ok, updated} = Billing.ensure_stripe_customer(user)
      assert updated.trial_ends_at
      assert DateTime.compare(updated.trial_ends_at, DateTime.utc_now()) == :gt
    end

    test "propagates a Stripe failure rather than returning a customerless user" do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _ ->
        {:error, %Stripe.Error{source: :stripe, code: :api_error, message: "nope"}}
      end)

      assert {:error, _} = Billing.ensure_stripe_customer(user)
      refute Repo.get(User, user.id).stripe_customer_id
    end
  end

  describe "checkout.session.completed" do
    defp checkout_event(customer, client_reference_id) do
      %Stripe.Event{
        type: "checkout.session.completed",
        data: %{object: %{customer: customer, client_reference_id: client_reference_id}}
      }
    end

    test "backfills the customer id via client_reference_id" do
      user = insert_verified_user()
      refute user.stripe_customer_id

      assert {:ok, updated} = Billing.sync_subscription(checkout_event("cus_orphan", user.id))
      assert updated.stripe_customer_id == "cus_orphan"
    end

    test "is a no-op when the customer is already linked" do
      user = insert_verified_user()
      {:ok, _} = Billing.attach_stripe_customer(user, "cus_known")

      assert {:ok, :ignored} = Billing.sync_subscription(checkout_event("cus_known", user.id))
    end

    test "reports an unknown client_reference_id rather than silently passing" do
      assert {:error, :user_not_found} =
               Billing.sync_subscription(checkout_event("cus_x", Ecto.UUID.generate()))
    end

    test "ignores a session with no customer" do
      assert {:ok, :ignored} = Billing.sync_subscription(checkout_event(nil, nil))
    end

    test "after backfill, the subscription webhook can find the user" do
      # The end-to-end point: this is what turns a charged-but-inactive account
      # into an active one.
      user = insert_verified_user()
      {:ok, _} = Billing.sync_subscription(checkout_event("cus_flow", user.id))

      event = %Stripe.Event{
        type: "customer.subscription.created",
        data: %{object: %{customer: "cus_flow", status: "active", trial_end: nil}}
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      assert updated.id == user.id
      assert updated.subscription_status == "active"
    end
  end

  describe "OAuth signups" do
    test "get a Stripe customer and a trial end date" do
      # The email+password path creates the customer after verification. OAuth
      # skips verification, so it used to create neither — every GitHub user
      # then walked into the orphaned-checkout bug above.
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_oauth"}} end)

      {:ok, user, :new} =
        Accounts.upsert_oauth_user("github", "gh-#{System.unique_integer([:positive])}", %{
          "email" => "oauth-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, updated} = Billing.create_stripe_customer(user)

      assert updated.stripe_customer_id == "cus_oauth"
      assert updated.trial_ends_at
    end
  end
end
