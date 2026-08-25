defmodule FountainWeb.CreditsSurfacesTest do
  @moduledoc """
  The four surfaces that show the prepaid balance render the one shape
  `Credits.summary/2` returns, and render nothing at all while the switch
  is off (ADR 0030). `async: false` because the switch is global config.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.Accounts.User
  alias Fountain.Credits
  alias Fountain.Repo

  @since ~U[2026-07-01 00:00:00Z]

  defp switch_on do
    cfg = Application.get_env(:fountain, :credits)
    Application.put_env(:fountain, :credits, cfg)
    on_exit(fn -> Application.put_env(:fountain, :credits, cfg) end)
  end

  defp insert_admin do
    {:ok, admin} = Fountain.Accounts.update_user_role(insert_empty_user(), "admin")
    admin
  end

  defp subscriber do
    user = insert_empty_user()

    {:ok, user} =
      user
      |> User.billing_changeset(%{stripe_customer_id: "cus_#{user.id}"})
      |> Repo.update()

    user
  end

  describe "billing off" do
    test "no balance anywhere, and the API says 404", %{conn: conn} do
      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
      user = subscriber()
      refute Fountain.Billing.enabled?()
      assert %{active?: false, balance_cents: 0} = Credits.summary(user)

      # The billing page does not exist on a billing-off instance; the
      # dashboard shows no balance; the API says billing is disabled.
      assert {:error, {:redirect, %{to: "/account"}}} =
               live(login_user(conn, user), ~p"/account/billing")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/dashboard")
      refute html =~ "Credits"

      {_rec, key} = insert_api_key(user)
      assert conn |> authed_with_key(key) |> get("/api/account/billing") |> json_response(404)
    end
  end

  describe "switch on" do
    setup do
      switch_on()
      :ok
    end

    test "summary carries the balance, the expiring grant and the purchased part" do
      user = subscriber()
      expires = ~U[2026-09-01 00:00:00Z]

      {:ok, _} =
        Credits.grant(user.id, 1000, "grant_opening", idempotency_key: "g", expires_at: expires)

      {:ok, _} = Credits.grant(user.id, 2500, "purchase", idempotency_key: "p")
      {:ok, _} = Credits.debit(user.id, 300, "burn_turn", idempotency_key: "b")

      user = Repo.reload!(user)
      summary = Credits.summary(user, now: ~U[2026-08-10 00:00:00Z])
      assert summary.active?
      assert summary.balance_cents == 3200
      assert summary.expiring_cents == 700
      assert summary.expires_at == expires
      assert summary.purchased_cents == 2500
      assert summary.price_card.turn_hour == 25
    end

    test "the billing page shows the balance, the price, the expiry and the ledger", %{conn: conn} do
      user = subscriber()

      {:ok, _} =
        Credits.grant(user.id, 1000, "grant_opening",
          idempotency_key: "g",
          expires_at: ~U[2099-09-01 00:00:00Z]
        )

      {:ok, _} =
        Credits.debit(user.id, 25, "burn_turn",
          idempotency_key: "b",
          metadata: %{"turn_seconds" => 3600}
        )

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      assert html =~ "id=\"credits\""
      assert html =~ "$9.75"
      assert html =~ "$0.25 per turn hour"
      assert html =~ "expires on Sep 1"
      assert html =~ "Opening credit"
      assert html =~ "Conversation time, 1.0h"
      refute html =~ "below zero"
    end

    test "a negative balance is called out, not hidden", %{conn: conn} do
      user = subscriber()
      {:ok, _} = Credits.debit(user.id, 40, "burn_turn", idempotency_key: "b")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      assert html =~ "-$0.40"
      assert html =~ "below zero"
    end

    test "the dashboard tile and the admin tile show the same number", %{conn: conn} do
      user = subscriber()
      {:ok, _} = Credits.grant(user.id, 1234, "purchase", idempotency_key: "p")

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/dashboard")
      assert html =~ "Credits"
      assert html =~ "$12.34"

      admin = insert_admin()
      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/users/#{user.id}")
      assert html =~ "Credits"
      assert html =~ "$12.34"
      assert html =~ "$12.34 bought"
    end

    test "an account sees the packs and buying redirects to Stripe",
         %{conn: conn} do
      user = subscriber()
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      assert html =~ "Buy $10.00"
      assert html =~ "Buy $100.00"

      Mimic.copy(Stripe.Checkout.Session)

      Mimic.stub(Stripe.Checkout.Session, :create, fn _ ->
        {:ok, %Stripe.Checkout.Session{url: "https://checkout.stripe.com/pack"}}
      end)

      {:ok, lv, _} = live(login_user(conn, user), ~p"/account/billing")

      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/pack"}}} =
               render_click(lv, "buy_credits", %{"cents" => "2500"})
    end

    test "the credits checkout endpoint", %{conn: conn} do
      user = subscriber()
      {_rec, key} = insert_api_key(user)

      Mimic.copy(Stripe.Checkout.Session)

      Mimic.stub(Stripe.Checkout.Session, :create, fn _ ->
        {:ok, %Stripe.Checkout.Session{url: "https://checkout.stripe.com/api"}}
      end)

      body =
        conn
        |> authed_with_key(key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/account/billing/credits/checkout", %{"cents" => 1000})
        |> json_response(200)

      assert body["data"]["url"] == "https://checkout.stripe.com/api"

      body =
        conn
        |> authed_with_key(key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/account/billing/credits/checkout", %{"cents" => 999})
        |> json_response(422)

      assert body["error"] == "unknown_pack"
    end

    test "the API carries the same shape", %{conn: conn} do
      user = subscriber()
      expires = ~U[2099-09-01 00:00:00Z]

      {:ok, _} =
        Credits.grant(user.id, 1000, "grant_opening", idempotency_key: "g", expires_at: expires)

      {_rec, key} = insert_api_key(user)

      body = conn |> authed_with_key(key) |> get("/api/account/billing") |> json_response(200)

      assert body["data"]["credits"] == %{
               "balance_cents" => 1000,
               "expiring_cents" => 1000,
               "expires_at" => "2099-09-01T00:00:00Z",
               "purchased_cents" => 0,
               "turn_hour_cents" => 25,
               "packs_cents" => [1000, 2500, 10_000]
             }
    end
  end
end
