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

  describe "billing disabled (#335, #479)" do
    # A self-hosted instance must never see this page — not even a degraded
    # version of it. Old bookmarks land on the core account page, which owns
    # export and deletion since #479.

    defp with_billing_disabled(fun) do
      previous = Application.get_env(:fountain, :billing_enabled)
      Application.put_env(:fountain, :billing_enabled, false)

      try do
        fun.()
      after
        Application.put_env(:fountain, :billing_enabled, previous)
      end
    end

    test "the page redirects to /account", %{conn: conn} do
      user = insert_verified_user()

      with_billing_disabled(fn ->
        assert {:error, {:redirect, %{to: "/account"}}} =
                 live(login_user(conn, user), ~p"/account/billing")
      end)
    end

    test "with billing enabled the page renders instead of redirecting", %{conn: conn} do
      user = insert_verified_user()

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      assert html =~ "Subscription"
      assert html =~ "Usage this period"
      assert html =~ "Turn hours"
    end
  end

  describe "comped accounts (#399)" do
    defp comped_user do
      user = insert_verified_user()

      {:ok, user} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "comped"})
        |> Fountain.Repo.update()

      user
    end

    test "are told the account is comped instead of being offered Checkout", %{conn: conn} do
      # comp_account/1 cancels every live subscription, so pre-#399 the
      # routing below read a comped account as a fresh customer, offered
      # Upgrade, charged them through Checkout — and the webhook adoption
      # then ignored the subscription entirely.
      {:ok, _lv, html} = live(login_user(conn, comped_user()), ~p"/account/billing")

      assert html =~ "This account is comped"
      refute html =~ ~s(phx-click="manage_subscription")
    end

    test "a hand-sent manage_subscription event is refused before Stripe", %{conn: conn} do
      test_pid = self()

      stub(Stripe.Checkout.Session, :create, fn _ ->
        send(test_pid, :checkout_reached)
        {:ok, %{url: "https://checkout.test"}}
      end)

      stub(Stripe.BillingPortal.Session, :create, fn _ ->
        send(test_pid, :portal_reached)
        {:ok, %{url: "https://portal.test"}}
      end)

      {:ok, lv, _html} = live(login_user(conn, comped_user()), ~p"/account/billing")
      html = render_click(lv, "manage_subscription", %{})

      assert html =~ "nothing to pay"
      refute_received :checkout_reached
      refute_received :portal_reached
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

  describe "the turn-hour meter (#1016)" do
    defp busy_hours(user, hours) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Billing.current_month_range()
      started = Enum.max([DateTime.add(now, -hours * 3600, :second), period_start], DateTime)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          provider: "sprites",
          status: "terminated",
          inserted_at: started,
          terminated_at: now
        )

      agent = insert_agent(user_id: user.id)

      conversation =
        insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      {:ok, _} =
        Fountain.Conversations._unsafe_create_turn(%{
          conversation_id: conversation.id,
          turn_number: 1,
          prompt: "hello",
          status: "completed",
          started_at: started,
          ended_at: now
        })

      :ok
    end

    test "shows hours used against the plan's allowance", %{conn: conn} do
      # Active: a trialing account is capped at the trial's 40 hours, which
      # the trial-specific tests below cover.
      user = insert_active_user(plan: "solo")
      busy_hours(user, 3)

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      assert html =~ "Turn hours"
      assert html =~ "of #{Fountain.Plans.included_turn_hours("solo")} included"
      assert html =~ "A turn hour is an hour with a prompt in flight"
    end

    # The trap this could create: showing "Solo" beside Trial's numbers, so a
    # customer evaluating Solo judges it on two sandboxes and forty hours and
    # concludes the product is unusable. Both have to be named.
    test "a trialing account sees the trial's numbers and what the tier raises them to",
         %{conn: conn} do
      user = insert_verified_user(plan: "team")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      team = Fountain.Plans.fetch!("team")
      trial = Fountain.Plans.fetch!("trial")

      assert html =~ "Trial, then Team"
      assert html =~ "of #{trial.included_turn_hours} included"
      assert html =~ "on trial"
      # The tier's numbers are stated as what subscribing raises them to.
      assert html =~
               "raises those to #{team.included_turn_hours} and #{team.concurrent_sandboxes}"

      refute html =~ "of #{team.included_turn_hours} included"
    end

    # The trial ties the cheapest tier on concurrency and hours, so the
    # "raises those to" sentence would name the numbers the customer already
    # has. Subscribing at the bottom of the ladder buys the clock, not
    # capacity, and the page has to say the true thing.
    test "a trialing account on a tier that ties the trial is not promised a raise",
         %{conn: conn} do
      solo = Fountain.Plans.fetch!("solo")
      trial = Fountain.Plans.fetch!("trial")
      # Guard: if Solo ever climbs above the trial again, this test is
      # asserting the wrong branch and should be deleted rather than fixed.
      assert solo.concurrent_sandboxes == trial.concurrent_sandboxes
      assert solo.included_turn_hours == trial.included_turn_hours

      user = insert_verified_user(plan: "solo")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      refute html =~ "raises those to"
      assert html =~ "which is what Solo carries too"
      assert html =~ "lifts the fourteen-day limit"
    end

    test "says nothing is limited when a tenant is over", %{conn: conn} do
      user = insert_verified_user(plan: "solo")
      busy_hours(user, 120)

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      # Reported, never enforced (#1016 step 4 is still open). A page that
      # implied a limit it does not have would be worse than no meter.
      assert html =~ "You are over the hours your plan includes"
      assert html =~ "Nothing is limited and"
    end

    test "labels a calendar-month window as the fallback it is", %{conn: conn} do
      # No Stripe period synced, so these numbers do not line up with an
      # invoice. Saying so is the whole reason `billing_period/2` returns a
      # source rather than a bare tuple.
      user = insert_verified_user()

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      assert html =~ "we do not have an invoiced period for this account yet"
    end

    test "does not label the window when it is the invoiced one", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        insert_verified_user()
        |> Fountain.Accounts.User.billing_changeset(%{
          subscription_status: "active",
          current_period_start: DateTime.add(now, -5, :day),
          current_period_end: DateTime.add(now, 25, :day)
        })
        |> Fountain.Repo.update()

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      refute html =~ "we do not have an invoiced period for this account yet"
    end
  end

  describe "the plan picker" do
    setup do
      Application.put_env(:fountain, :stripe_price_ids, %{
        "solo" => "price_solo",
        "team" => "price_team",
        "scale" => "price_scale"
      })

      on_exit(fn -> Application.delete_env(:fountain, :stripe_price_ids) end)
      :ok
    end

    defp subscribed_user(plan) do
      user = billing_state("active", "cus_picker")

      {:ok, user} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{
          stripe_subscription_id: "sub_picker",
          plan: plan
        })
        |> Fountain.Repo.update()

      user
    end

    test "shows every sellable plan, marks the current one, and never the closed one",
         %{conn: conn} do
      user = subscribed_user("legacy")
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      assert html =~ "Change plan"
      assert html =~ "Solo"
      assert html =~ "Team"
      assert html =~ "Scale"
      # The current plan is named in the status card, but the picker offers
      # only the three public tiers — a closed price is not something to
      # switch back onto.
      refute html =~ "Switch to Legacy"
      assert html =~ "an earlier plan we no longer sell"
      # The hours are part of what a customer is choosing between. Derived
      # from the catalog: which numbers the tiers carry is pinned in
      # plans_test.exs, and this is about the picker rendering them.
      assert html =~ "#{Fountain.Plans.included_turn_hours("solo")} turn hours included"
      assert html =~ "#{Fountain.Plans.included_turn_hours("scale")} turn hours included"
    end

    test "the current plan is not offered as a switch", %{conn: conn} do
      user = subscribed_user("team")
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      assert html =~ "Current plan"
      refute html =~ "Upgrade to Team"
    end

    test "is hidden for a comped account", %{conn: conn} do
      user = billing_state("comped", "cus_comped")
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      refute html =~ "Change plan"
    end

    test "is hidden when there is no subscription to reprice", %{conn: conn} do
      user = billing_state("canceled", "cus_none")
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")

      refute html =~ "Change plan"
    end

    test "a switch reports success and leaves the plan to the webhook", %{conn: conn} do
      user = subscribed_user("solo")

      stub(Stripe.Subscription, :retrieve, fn "sub_picker" ->
        {:ok, %{id: "sub_picker", items: %{data: [%{id: "si", price: %{id: "price_solo"}}]}}}
      end)

      stub(Stripe.SubscriptionItem, :update, fn _, _ -> {:ok, %{id: "si"}} end)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      html = render_click(lv, "change_plan", %{"plan" => "team"})

      assert html =~ "Switched to Team"
      assert Fountain.Repo.get(Fountain.Accounts.User, user.id).plan == "solo"
    end

    # The realistic cause is a price id removed from the config out from under
    # a live subscription — most likely STRIPE_PRICE_ID, which every `legacy`
    # account still points at. "Try again" would send them round a loop that
    # cannot work, so this path says something different.
    test "an unrecognised subscription price does not say 'try again'", %{conn: conn} do
      user = subscribed_user("legacy")

      stub(Stripe.Subscription, :retrieve, fn "sub_picker" ->
        {:ok, %{id: "sub_picker", items: %{data: [%{id: "si", price: %{id: "price_gone"}}]}}}
      end)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account/billing")
      html = render_click(lv, "change_plan", %{"plan" => "team"})

      assert html =~ "could not match your subscription to a plan"
      refute html =~ "Please try again"
    end
  end
end
