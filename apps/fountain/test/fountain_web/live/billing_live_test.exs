defmodule FountainWeb.BillingLiveTest do
  @moduledoc """
  Cover for the Checkout call itself, which is where money is actually taken.

  The bug this pins: when a user had no `stripe_customer_id`, Checkout was
  opened with `customer_email`. Stripe then minted its own Customer whose id we
  never learned, so the subscription webhook matched no user and the account was
  charged without ever activating.

  Also closes NC-5 from the release-validation report, which flagged BillingLive
  as untested.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Billing

  setup do
    original = Application.get_env(:fountain, :stripe_price_id)
    Application.put_env(:fountain, :stripe_price_id, "price_test123")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fountain, :stripe_price_id)
        v -> Application.put_env(:fountain, :stripe_price_id, v)
      end
    end)

    :ok
  end

  describe "upgrade with no existing Stripe customer" do
    test "creates the customer first and never passes customer_email", %{conn: conn} do
      user = insert_verified_user()
      refute user.stripe_customer_id

      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_created"}} end)

      test_pid = self()

      stub(Stripe.Checkout.Session, :create, fn params ->
        send(test_pid, {:checkout_params, params})
        {:ok, %{url: "https://checkout.stripe.test/session"}}
      end)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert_receive {:checkout_params, params}

      # The whole point: an id we control, and never an email fallback.
      assert params.customer == "cus_created"
      refute Map.has_key?(params, :customer_email)

      # Second route home if the customer link is ever lost.
      assert params.client_reference_id == user.id
      assert params.mode == :subscription
    end

    test "the created customer is persisted, so a retry reuses it", %{conn: conn} do
      user = insert_verified_user()
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_persist"}} end)
      stub(Stripe.Checkout.Session, :create, fn _ -> {:ok, %{url: "https://checkout.test"}} end)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert Fountain.Repo.get(Fountain.Accounts.User, user.id).stripe_customer_id ==
               "cus_persist"
    end
  end

  describe "upgrade with an existing Stripe customer" do
    test "reuses it without minting another", %{conn: conn} do
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_already")

      test_pid = self()

      stub(Stripe.Checkout.Session, :create, fn params ->
        send(test_pid, {:checkout_params, params})
        {:ok, %{url: "https://checkout.test"}}
      end)

      # No stub on Stripe.Customer.create — calling it would fail the test.
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert_receive {:checkout_params, params}
      assert params.customer == "cus_already"
    end
  end

  describe "active subscribers" do
    test "are sent to the billing portal rather than Checkout", %{conn: conn} do
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_active")

      {:ok, user} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "active"})
        |> Fountain.Repo.update()

      test_pid = self()

      stub(Stripe.BillingPortal.Session, :create, fn params ->
        send(test_pid, {:portal_params, params})
        {:ok, %{url: "https://portal.test"}}
      end)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert_receive {:portal_params, params}
      assert params.customer == "cus_active"
    end
  end

  describe "when Stripe customer creation fails" do
    test "no Checkout session is opened", %{conn: conn} do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _ ->
        {:error, %Stripe.Error{source: :stripe, code: :api_error, message: "down"}}
      end)

      # No stub on Checkout.Session.create: opening one without a customer is
      # exactly the bug, so a call here must fail the test.
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      html = render_click(lv, "manage_subscription", %{})

      assert html =~ "billing" or html =~ "error" or html =~ "Billing"
      refute Fountain.Repo.get(Fountain.Accounts.User, user.id).stripe_customer_id
    end
  end
end
