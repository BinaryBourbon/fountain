defmodule FountainWeb.AgentsLive.VersionsTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Agents

  setup %{conn: conn} do
    user = insert_verified_user()
    conn = login_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "versions page" do
    test "renders the initial version", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/versions")

      assert html =~ "Version 1"
      assert html =~ "Initial version"
      assert html =~ "current"
    end

    test "renders a diff for a config change", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id, system: "be helpful")
      {:ok, _} = Agents.update_agent(agent, %{"system" => "be terse"})

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}/versions")

      assert html =~ "Version 2"
      assert html =~ "be helpful"
      assert html =~ "be terse"
    end

    test "rollback applies the old config as a new version", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id, system: "be helpful")
      {:ok, _} = Agents.update_agent(agent, %{"system" => "be terse"})

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}/versions")

      html = render_click(view, "rollback", %{"version" => "1"})

      assert html =~ "Rolled back to version 1"
      assert html =~ "Version 3"

      reloaded = Agents.get_agent!(agent.id, user.id)
      assert reloaded.system == "be helpful"
    end

    test "404s for another tenant's agent", %{conn: conn} do
      other = insert_verified_user()
      agent = insert_agent(user_id: other.id)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/agents/#{agent.id}/versions")
      end
    end

    test "redirects unauthenticated visitors to login", %{user: user} do
      agent = insert_agent(user_id: user.id)

      conn = build_conn()
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/agents/#{agent.id}/versions")
      assert path =~ "/auth/login"
    end
  end
end
