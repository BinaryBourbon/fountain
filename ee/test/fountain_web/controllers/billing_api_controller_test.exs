defmodule FountainWeb.BillingApiControllerTest do
  @moduledoc """
  Billing self-serve over the API (#524).

  A CLI user who hit the subscription gate got a 402 and no programmatic route
  out of it: usage numbers, Checkout and the Portal all lived in `BillingLive`.
  """

  # async: false — billing_enabled and stripe_price_id are application env.
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.Repo

  setup do
    original = Application.get_env(:fountain, :stripe_price_id)
    Application.put_env(:fountain, :stripe_price_id, "price_test123")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fountain, :stripe_price_id)
        v -> Application.put_env(:fountain, :stripe_price_id, v)
      end
    end)

    # Active, not trialing: these assert what a *plan* reports, and a trial is
    # deliberately capped below its tier (`Fountain.Plans`' `trial` plan).
    user = insert_active_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  defp billing_state(user, attrs) do
    {:ok, user} = user |> User.billing_changeset(attrs) |> Repo.update()
    user
  end

  defp with_billing_disabled(fun) do
    previous = Application.get_env(:fountain, :billing_enabled)
    Application.put_env(:fountain, :billing_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:fountain, :billing_enabled, previous)
    end
  end

  defp no_live_subscription do
    stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: []}} end)
  end

  describe "GET /api/account/billing" do
    test "reports status, dates and current-period usage", %{conn: conn, user: user, key: key} do
      trial_end = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
      billing_state(user, %{subscription_status: "trialing", trial_ends_at: trial_end})

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["status"] == "trialing"
      assert body["data"]["trial_ends_at"]
      assert body["data"]["usage"]["conversations"] == 0
      assert body["data"]["usage"]["turns"] == 0
      assert body["data"]["usage"]["sandbox_minutes"] == 0
      assert body["data"]["usage"]["sandbox_minutes_by_provider"] == %{}
      assert body["data"]["period"]["start"]
      assert body["data"]["period"]["end"]
      # No subscription period synced yet, so the numbers cover a calendar
      # month — and the response has to say so rather than let a client show
      # an allowance against a window nobody is invoiced for.
      assert body["data"]["period"]["source"] == "calendar_month"
    end

    test "turn hours travel with the usage, beside the plan's grant size", %{
      conn: conn,
      user: user,
      key: key
    } do
      # Turn hours, not sandbox minutes: an hour with a prompt in flight.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Billing.current_month_range()
      started = Enum.max([DateTime.add(now, -30, :minute), period_start], DateTime)

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

      expected = Float.round(DateTime.diff(now, started, :second) / 3600, 2)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      included = Fountain.Plans.included_credit_cents(Fountain.Plans.default_slug())

      assert body["data"]["usage"]["turn_hours"] == expected
      assert body["data"]["plan"]["included_credit_cents"] == included
      # The allowance shape is gone (ADR 0030): credits are what act.
      refute Map.has_key?(body["data"]["usage"], "turn_hours_included")
    end

    test "an idle sandbox spends sandbox minutes and no turn hours", %{
      conn: conn,
      user: user,
      key: key
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Billing.current_month_range()
      started = Enum.max([DateTime.add(now, -30, :minute), period_start], DateTime)

      insert_sandbox(
        user_id: user.id,
        provider: "sprites",
        status: "terminated",
        inserted_at: started,
        terminated_at: now
      )

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["usage"]["sandbox_minutes"] > 0
      assert body["data"]["usage"]["turn_hours"] == 0.0
    end

    test "sandbox minutes are reported per provider", %{conn: conn, user: user, key: key} do
      # Which provider ran the minutes is what makes them attributable to a
      # cost: a minute on each is bought at a different price.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Billing.current_month_range()

      # Clamped to the month the endpoint reports on, so the run is ten minutes
      # long every day except the first ten minutes of a month, when it is
      # shorter — and the expected value follows it rather than going stale.
      started =
        [DateTime.add(now, -10, :minute), period_start]
        |> Enum.max(DateTime)

      insert_sandbox(
        user_id: user.id,
        provider: "e2b",
        status: "terminated",
        inserted_at: started,
        terminated_at: now
      )

      expected = Float.round(DateTime.diff(now, started, :second) / 60, 2)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["usage"]["sandbox_minutes"] == expected
      assert body["data"]["usage"]["sandbox_minutes_by_provider"] == %{"e2b" => expected}
    end

    test "trial dates answer the 'why did my API calls start failing' question", %{
      conn: conn,
      user: user,
      key: key
    } do
      # An expiring trial is invisible from /api/auth/me, which carries only
      # subscription_status.
      ends_at = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      billing_state(user, %{subscription_status: "trialing", trial_ends_at: ends_at})

      body = conn |> authed_with_key(key) |> get("/api/account/billing") |> json_response(200)

      assert {:ok, returned, _} = DateTime.from_iso8601(body["data"]["trial_ends_at"])
      assert DateTime.compare(returned, ends_at) == :eq
    end

    test "is 404 with billing: disabled on a self-hosted instance", %{conn: conn, key: key} do
      with_billing_disabled(fn ->
        body =
          conn
          |> authed_with_key(key)
          |> get("/api/account/billing")
          |> json_response(404)

        assert body["billing"] == "disabled"
      end)
    end

    test "a sprite token cannot read the account's billing state", %{conn: conn, user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> get("/api/account/billing")
      |> json_response(403)
    end

    test "requires authentication", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/account/billing")
      |> json_response(401)
    end
  end

  describe "POST /api/account/billing/portal" do
    test "returns a portal URL for an existing customer", %{conn: conn, user: user, key: key} do
      billing_state(user, %{subscription_status: "active", stripe_customer_id: "cus_123"})

      stub(Stripe.BillingPortal.Session, :create, fn params ->
        assert params.customer == "cus_123"
        {:ok, %{url: "https://billing.stripe.com/session/abc"}}
      end)

      body =
        conn
        |> authed_with_key(key)
        |> post("/api/account/billing/portal")
        |> json_response(200)

      assert body["data"]["url"] == "https://billing.stripe.com/session/abc"
    end

    test "refuses a comped account", %{conn: conn, user: user, key: key} do
      billing_state(user, %{subscription_status: "comped", stripe_customer_id: "cus_123"})
      reject(&Stripe.BillingPortal.Session.create/1)

      body =
        conn |> authed_with_key(key) |> post("/api/account/billing/portal") |> json_response(422)

      assert body["error"] == "comped"
    end

    test "refuses an account that was never a Stripe customer", %{conn: conn, key: key} do
      reject(&Stripe.BillingPortal.Session.create/1)

      body =
        conn |> authed_with_key(key) |> post("/api/account/billing/portal") |> json_response(422)

      assert body["error"] == "no_stripe_customer"
    end

    test "an unreachable Stripe is 502, not a 500", %{conn: conn, user: user, key: key} do
      billing_state(user, %{subscription_status: "active", stripe_customer_id: "cus_123"})
      stub(Stripe.BillingPortal.Session, :create, fn _ -> {:error, :nxdomain} end)

      body =
        conn |> authed_with_key(key) |> post("/api/account/billing/portal") |> json_response(502)

      assert body["error"] == "stripe_unreachable"
    end
  end

  describe "POST /api/account/billing/checkout" do
    test "returns a checkout URL, with the customer and promotion codes set", %{
      conn: conn,
      user: user,
      key: key
    } do
      billing_state(user, %{subscription_status: "canceled", stripe_customer_id: "cus_123"})
      no_live_subscription()

      stub(Stripe.Checkout.Session, :create, fn params ->
        # The bug this pins in the LiveView too: never customer_email, or
        # Stripe mints a customer whose id we never learn.
        assert params.customer == "cus_123"
        assert params.client_reference_id == user.id
        assert params.allow_promotion_codes
        assert params.line_items == [%{price: "price_test123", quantity: 1}]
        {:ok, %{url: "https://checkout.stripe.com/session/xyz"}}
      end)

      body =
        conn
        |> authed_with_key(key)
        |> post("/api/account/billing/checkout")
        |> json_response(200)

      assert body["data"]["url"] == "https://checkout.stripe.com/session/xyz"
    end

    test "refuses when Stripe already holds a live subscription", %{
      conn: conn,
      user: user,
      key: key
    } do
      # Checkout on top of a live subscription mints a duplicate. The LiveView
      # silently routes to the Portal; an API caller who asked for Checkout
      # gets told which door to use instead.
      billing_state(user, %{subscription_status: "canceled", stripe_customer_id: "cus_123"})
      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: [%{status: "active"}]}} end)
      reject(&Stripe.Checkout.Session.create/1)

      body =
        conn
        |> authed_with_key(key)
        |> post("/api/account/billing/checkout")
        |> json_response(409)

      assert body["error"] == "subscription_exists"
    end

    test "refuses when Stripe cannot be asked, rather than guessing", %{
      conn: conn,
      user: user,
      key: key
    } do
      billing_state(user, %{subscription_status: "canceled", stripe_customer_id: "cus_123"})
      stub(Stripe.Subscription, :list, fn _ -> {:error, :timeout} end)
      reject(&Stripe.Checkout.Session.create/1)

      conn |> authed_with_key(key) |> post("/api/account/billing/checkout") |> json_response(502)
    end

    test "refuses a comped account", %{conn: conn, user: user, key: key} do
      billing_state(user, %{subscription_status: "comped", stripe_customer_id: "cus_123"})
      no_live_subscription()
      reject(&Stripe.Checkout.Session.create/1)

      body =
        conn
        |> authed_with_key(key)
        |> post("/api/account/billing/checkout")
        |> json_response(422)

      assert body["error"] == "comped"
    end

    test "is 404 when billing is disabled", %{conn: conn, key: key} do
      with_billing_disabled(fn ->
        reject(&Stripe.Checkout.Session.create/1)

        conn
        |> authed_with_key(key)
        |> post("/api/account/billing/checkout")
        |> json_response(404)
      end)
    end

    test "a sprite token cannot start a subscription", %{conn: conn, user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)
      reject(&Stripe.Checkout.Session.create/1)

      conn
      |> authed_with_key(sprite_key)
      |> post("/api/account/billing/checkout")
      |> json_response(403)
    end
  end
end
