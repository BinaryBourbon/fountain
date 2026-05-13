defmodule FountainWeb.ConversationsLive.NewTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders new conversation form for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/conversations/new")

      assert html =~ "phx-submit"
      assert html =~ "<textarea"
    end

    test "renders empty state when user has no agents", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/conversations/new")

      assert html =~ "No agents defined yet"
      refute html =~ "phx-submit"
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/conversations/new")
      assert path =~ "/auth/login"
    end

    test "redirects canceled subscription user to billing", %{conn: conn} do
      user = insert_verified_user()

      {:ok, updated} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "canceled"})
        |> Fountain.Repo.update()

      conn = login_user(conn, updated)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/conversations/new")
      assert path == "/account/billing"
    end
  end

  describe "navigation idempotency" do
    # Regression: the sidebar '+ New Conversation' button previously used
    # navigate= which is a no-op when already on /conversations/new.
    # This test ensures the page mounts fresh each time (the href= fix
    # is on the client side, but we verify mount is side-effect free).
    test "mounting /conversations/new twice in a row succeeds both times", %{conn: conn} do
      user = insert_verified_user()
      insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view1, html1} = live(conn, ~p"/conversations/new")
      {:ok, _view2, html2} = live(conn, ~p"/conversations/new")

      assert html1 =~ "phx-submit"
      assert html2 =~ "phx-submit"
    end
  end
end

# Submit tests require Mimic global mode (stubs visible to the LiveView
# process), which is incompatible with async: true — isolated in a
# separate non-async module.
defmodule FountainWeb.ConversationsLive.NewSubmitTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  setup :set_mimic_global

  describe "submit" do
    setup %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/conversations/new")
      %{lv: lv, agent: agent}
    end

    test "redirects to the new conversation on success", %{lv: lv, agent: agent} do
      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, :test_pid}
      end)

      params = %{"agent_id" => agent.id, "prompt" => "hello", "vault_id" => ""}

      assert {:error, {:live_redirect, %{to: path}}} =
               lv
               |> element("form[phx-submit='submit']")
               |> render_submit(%{"conv" => params})

      assert String.starts_with?(path, "/conversations/")
    end

    test "shows agent-not-found flash when agent_id is unknown", %{lv: lv} do
      params = %{"agent_id" => Ecto.UUID.generate(), "prompt" => "hello", "vault_id" => ""}

      html =
        lv
        |> element("form[phx-submit='submit']")
        |> render_submit(%{"conv" => params})

      assert html =~ "Agent not found"
    end

    test "redirects to the conversation page when server fails to start", %{lv: lv, agent: agent} do
      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:error, :test_failure}
      end)

      params = %{"agent_id" => agent.id, "prompt" => "hello", "vault_id" => ""}

      assert {:error, {:live_redirect, %{to: path}}} =
               lv
               |> element("form[phx-submit='submit']")
               |> render_submit(%{"conv" => params})

      assert String.starts_with?(path, "/conversations/")
    end
  end
end
