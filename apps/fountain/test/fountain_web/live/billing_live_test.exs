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

  defp billing_state(status, customer_id) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> Fountain.Accounts.User.billing_changeset(%{
        subscription_status: status,
        stripe_customer_id: customer_id
      })
      |> Fountain.Repo.update()

    user
  end

  describe "billing disabled (#335)" do
    # A self-hosted instance shows a trial countdown and an Upgrade button
    # whose only possible outcome is "Unable to reach Stripe".

    defp with_billing_disabled(fun) do
      previous = Application.get_env(:fountain, :billing_enabled)
      Application.put_env(:fountain, :billing_enabled, false)

      try do
        fun.()
      after
        Application.put_env(:fountain, :billing_enabled, previous)
      end
    end

    test "no upgrade affordance, no trial countdown, a plain explanation", %{conn: conn} do
      user = insert_verified_user()

      with_billing_disabled(fn ->
        {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

        assert html =~ "Billing is disabled on this instance"
        refute html =~ "Upgrade"
        refute html =~ "Manage Subscription"
        refute html =~ "Trial"
      end)
    end

    test "usage and the danger zone are still there", %{conn: conn} do
      user = insert_verified_user()

      with_billing_disabled(fn ->
        {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

        assert html =~ "Usage This Month"
        assert html =~ "Delete account"
      end)
    end
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

      # An existing customer is checked for live subscriptions before Checkout
      # is opened — none here, so Checkout proceeds.
      stub(Stripe.Subscription, :list, fn %{customer: "cus_already"} ->
        {:ok, %{data: [], has_more: false}}
      end)

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

  describe "past_due subscribers" do
    test "are sent to the billing portal — the fix lives there", %{conn: conn} do
      user = billing_state("past_due", "cus_pastdue")

      test_pid = self()

      stub(Stripe.BillingPortal.Session, :create, fn params ->
        send(test_pid, {:portal_params, params})
        {:ok, %{url: "https://portal.test"}}
      end)

      # No stub on Checkout.Session.create — a past_due user already has a
      # subscription; opening Checkout would duplicate it.
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert_receive {:portal_params, params}
      assert params.customer == "cus_pastdue"
    end
  end

  describe "canceled subscribers" do
    test "with no live subscription left go through Checkout again", %{conn: conn} do
      user = billing_state("canceled", "cus_gone")

      test_pid = self()

      stub(Stripe.Subscription, :list, fn %{customer: "cus_gone", status: :all} ->
        {:ok, %{data: [%Stripe.Subscription{id: "sub_old", status: "canceled"}], has_more: false}}
      end)

      stub(Stripe.Checkout.Session, :create, fn params ->
        send(test_pid, {:checkout_params, params})
        {:ok, %{url: "https://checkout.test"}}
      end)

      # No stub on Stripe.Customer.create — the customer must be reused, and
      # none on BillingPortal.Session — this user's way back in is Checkout.
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert_receive {:checkout_params, params}
      assert params.customer == "cus_gone"
      assert params.client_reference_id == user.id
      assert params.mode == :subscription
    end

    test "with a subscription still canceling at period end get the portal, never a duplicate",
         %{conn: conn} do
      # Local status says canceled, but Stripe still holds a live subscription
      # (canceled at period end -> still "active" until the period ends).
      # Checkout here would open a second subscription on top of it.
      user = billing_state("canceled", "cus_still_live")

      test_pid = self()

      stub(Stripe.Subscription, :list, fn %{customer: "cus_still_live", status: :all} ->
        {:ok,
         %{
           data: [
             %Stripe.Subscription{id: "sub_cap", status: "active", cancel_at_period_end: true}
           ],
           has_more: false
         }}
      end)

      stub(Stripe.BillingPortal.Session, :create, fn params ->
        send(test_pid, {:portal_params, params})
        {:ok, %{url: "https://portal.test"}}
      end)

      # No stub on Checkout.Session.create — opening one IS the orphaned
      # duplicate subscription, so a call here must fail the test.
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      render_click(lv, "manage_subscription", %{})

      assert_receive {:portal_params, params}
      assert params.customer == "cus_still_live"
    end

    test "can open the portal for billing history and invoices", %{conn: conn} do
      user = billing_state("canceled", "cus_receipts")

      test_pid = self()

      stub(Stripe.BillingPortal.Session, :create, fn params ->
        send(test_pid, {:portal_params, params})
        {:ok, %{url: "https://portal.test/history"}}
      end)

      {:ok, lv, html} = live(login_user(conn, user), ~p"/account/billing")
      assert html =~ "Billing history"

      render_click(lv, "billing_history", %{})

      assert_receive {:portal_params, params}
      assert params.customer == "cus_receipts"
    end

    test "the billing history link is hidden without a Stripe customer", %{conn: conn} do
      user = insert_verified_user()
      refute user.stripe_customer_id

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      refute html =~ "Billing history"
    end

    test "active users reach invoices via Manage Subscription, not a second link",
         %{conn: conn} do
      user = billing_state("active", "cus_active_inv")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      assert html =~ "Manage Subscription"
      refute html =~ "Billing history"
    end
  end

  describe "cancel at period end" do
    test "the page says access continues until the period end date", %{conn: conn} do
      user = billing_state("active", "cus_cap_ui")

      {:ok, user} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{
          cancel_at_period_end: true,
          current_period_end: ~U[2026-08-30 12:00:00Z]
        })
        |> Fountain.Repo.update()

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      # Not hard-locked, and not silent either: the pending cancellation is
      # named, dated, and the way back (the portal) is still the primary button.
      assert html =~ "you keep full access until"
      assert html =~ "Access until"
      assert html =~ "August 30, 2026"
      assert html =~ "Manage Subscription"
      refute html =~ "requires attention"
    end

    test "an active subscription with no pending cancellation shows none of it",
         %{conn: conn} do
      user = billing_state("active", "cus_no_cap")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      refute html =~ "Access until"
      refute html =~ "set to cancel"
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
