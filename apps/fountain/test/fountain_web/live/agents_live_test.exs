defmodule FountainWeb.AgentsLive.IndexTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "index" do
    test "renders agent list for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ agent.name
      assert html =~ "+ New agent"
      assert html =~ "Edit"
    end

    test "renders empty state when user has no agents", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "No agents yet"
    end

    test "new agent button uses plain href (not LiveView navigate)", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents")

      # Must be a plain href so the browser always performs a real navigation.
      # Regression: navigate= was a no-op in some LiveSocket states (e.g. after
      # visiting a conversation page where JS hooks had been mounted).
      assert has_element?(view, ~s(a[href="/agents/new"]))
      refute has_element?(view, ~s(a[data-phx-link][href="/agents/new"]))
    end

    test "edit button uses plain href (not LiveView navigate)", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, ~s(a[href="/agents/#{agent.id}/edit"]))
      refute has_element?(view, ~s(a[data-phx-link][href="/agents/#{agent.id}/edit"]))
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents")
      assert path =~ "/auth/login"
    end
  end

  describe "new" do
    test "renders new agent form for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/new")

      assert html =~ "New agent"
      assert html =~ "phx-submit"
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/new")
      assert path =~ "/auth/login"
    end
  end

  describe "edit" do
    test "renders edit form for existing agent", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/edit")

      assert html =~ "Edit agent"
      assert html =~ agent.name
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert path =~ "/auth/login"
    end
  end
end
