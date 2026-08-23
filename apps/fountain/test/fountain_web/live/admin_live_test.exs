defmodule FountainWeb.AdminLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Index — access control" do
    test "admin user can access /admin", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
      assert html =~ "Users"
    end

    test "regular user is redirected away from /admin", %{conn: conn} do
      user = insert_active_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path =~ "/auth/login"
    end
  end

  describe "AdminLive.Index — funnel section" do
    test "renders stage tiles with counts and conversions", %{conn: conn} do
      admin = insert_admin()
      _unverified = insert_user()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Funnel"
      assert html =~ "Registered"
      assert html =~ "Verified"
      assert html =~ "Onboarded"
      assert html =~ "Activated"
      assert html =~ "Subscribed"
      # 2 registered, 1 verified → 50% conversion tile
      assert html =~ "50% of prev"
    end

    test "shows the stalled-verified breakdown", %{conn: conn} do
      admin = insert_admin()
      stalled = insert_active_user()
      insert_agent(user_id: stalled.id)
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      # admin + stalled are both verified with no conversations
      assert html =~ "2 verified users have never started a conversation"
      assert html =~ "built an agent: 1"
    end
  end
end
