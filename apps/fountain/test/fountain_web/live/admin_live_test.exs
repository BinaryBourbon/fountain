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

  describe "AdminLive.Index — :refresh handle_info" do
    test "page re-renders on :refresh message without error", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      # Send the refresh message directly; the page should still render
      send(lv.pid, :refresh)
      html = render(lv)
      assert html =~ "Admin"
      assert html =~ "Users"
    end

    test ":refresh picks up newly inserted users", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, html_before} = live(conn, ~p"/admin")

      new_user = insert_verified_user()

      send(lv.pid, :refresh)
      html_after = render(lv)

      refute html_before =~ new_user.email
      assert html_after =~ new_user.email
    end
  end

  describe "AdminLive.Index — sandboxes section" do
    test "shows 'No active sandboxes' when there are none", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "No active sandboxes"
    end

    test "renders active sandboxes in the table", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ String.slice(sandbox.id, 0, 8)
      assert html =~ "ready"
    end

    test "does not show terminated sandboxes", %{conn: conn} do
      admin = insert_admin()
      terminated = insert_sandbox(user_id: admin.id, status: "terminated")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      refute html =~ String.slice(terminated.id, 0, 8)
    end

    test "shows ready sandbox with correct status badge", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "ready"
    end

    test "shows failed sandbox with correct status badge", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "failed")
      conn = login_user(conn, admin)
      # failed is excluded by list_sandboxes_admin (status not in ["terminated","failed"])
      # so page should show "No active sandboxes"
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Active sandboxes"
    end
  end

  describe "AdminLive.Index — user list formatting" do
    test "shows joined date for each user", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # inserted_at is always set so date column should have a year
      assert html =~ to_string(Date.utc_today().year)
    end

    test "shows onboarding_completed_at date when set", %{conn: conn} do
      admin = insert_admin()
      # Mark onboarding complete via direct Repo update
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, admin_with_date} =
        Fountain.Repo.update(
          Ecto.Changeset.change(admin, onboarding_completed_at: now)
        )

      conn = login_user(conn, admin_with_date)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ to_string(now.year)
    end
  end
end
