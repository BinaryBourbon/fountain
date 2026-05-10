defmodule FountainWeb.AdminLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_verified_user(overrides)
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
      user = insert_verified_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path =~ "/auth/login"
    end
  end

  describe "AdminLive.Index — user list" do
    test "displays all users", %{conn: conn} do
      admin = insert_admin()
      other = insert_verified_user()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ admin.email
      assert html =~ other.email
    end

    test "shows onboarding state for each user", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "step_1"
    end
  end

  describe "AdminLive.Index — toggle_admin" do
    test "promotes a regular user to admin", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv |> element("button[phx-value-id='#{target.id}']", "Make admin") |> render_click()

      updated = Accounts.get_user!(target.id)
      assert updated.role == "admin"
    end

    test "demotes an admin to regular user", %{conn: conn} do
      admin = insert_admin()
      target = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv |> element("button[phx-value-id='#{target.id}']", "Remove admin") |> render_click()

      updated = Accounts.get_user!(target.id)
      assert updated.role == "user"
    end
  end
end
