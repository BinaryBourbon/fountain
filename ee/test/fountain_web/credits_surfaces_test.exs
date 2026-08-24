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
    Application.put_env(:fountain, :credits, Keyword.put(cfg, :pricing_since, @since))
    on_exit(fn -> Application.put_env(:fountain, :credits, cfg) end)
  end

  defp insert_admin do
    {:ok, admin} = Fountain.Accounts.update_user_role(insert_active_user(), "admin")
    admin
  end

  defp subscriber do
    user = insert_active_user()
    {:ok, user} = user |> User.billing_changeset(%{plan: "solo"}) |> Repo.update()
    user
  end

  describe "switch off" do
    test "no balance anywhere, and the API says null", %{conn: conn} do
      user = subscriber()
      refute Credits.active?()
      assert %{active?: false, balance_cents: 0} = Credits.summary(user)

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account/billing")
      refute html =~ "id=\"credits\""

      {:ok, _lv, html} = live(login_user(conn, user), ~p"/dashboard")
      refute html =~ "Credits"

      {_rec, key} = insert_api_key(user)
      body = conn |> authed_with_key(key) |> get("/api/account/billing") |> json_response(200)
      assert Map.has_key?(body["data"], "credits")
      assert body["data"]["credits"] == nil
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
        Credits.grant(user.id, 1000, "grant_tier", idempotency_key: "g", expires_at: expires)

      {:ok, _} = Credits.grant(user.id, 2500, "purchase", idempotency_key: "p")
      {:ok, _} = Credits.debit(user.id, 300, "burn_turn", idempotency_key: "b")

      user = Repo.reload!(user)
      summary = Credits.summary(user, now: ~U[2026-08-10 00:00:00Z])
      assert summary.active?
      assert summary.balance_cents == 3200
      assert summary.expiring_cents == 700
      assert summary.expires_at == expires
      assert summary.purchased_cents == 2500
      assert summary.turn_hour_cents == 25
    end

    test "the billing page shows the balance, the price, the expiry and the ledger", %{conn: conn} do
      user = subscriber()

      {:ok, _} =
        Credits.grant(user.id, 1000, "grant_tier",
          idempotency_key: "g",
          expires_at: ~U[2099-09-01 00:00:00Z],
          metadata: %{"plan" => "solo"}
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
      assert html =~ "Solo plan credit"
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

    test "the API carries the same shape", %{conn: conn} do
      user = subscriber()
      expires = ~U[2099-09-01 00:00:00Z]

      {:ok, _} =
        Credits.grant(user.id, 1000, "grant_tier", idempotency_key: "g", expires_at: expires)

      {_rec, key} = insert_api_key(user)

      body = conn |> authed_with_key(key) |> get("/api/account/billing") |> json_response(200)

      assert body["data"]["credits"] == %{
               "balance_cents" => 1000,
               "expiring_cents" => 1000,
               "expires_at" => "2099-09-01T00:00:00Z",
               "purchased_cents" => 0,
               "turn_hour_cents" => 25
             }
    end
  end
end
