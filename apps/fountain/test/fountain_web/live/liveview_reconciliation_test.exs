defmodule FountainWeb.LiveviewReconciliationTest do
  use FountainWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Fountain.{Agents, Conversations, Environments, Vaults}

  # Regression tests for #401: LiveView state loaded at mount and never
  # reconciled — a log viewer subscribed to a topic nothing publishes on, a
  # conversation header keyed off a mount-time struct, delete handlers that
  # crashed on rows deleted elsewhere, and an unmapped `idle` badge.

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  describe "log viewer topic (#401 item 1)" do
    test "receives live log events", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      # The real publisher path — publish_stage broadcasts on
      # "conv:<conversation_id>". The old subscription was on
      # "conv:<user>:<conv>", which nothing publishes on, so this event
      # never arrived and the page was a static snapshot.
      Conversations.publish_stage(conv.id, "provision", "done", %{})

      assert render(view) =~ "provision"
    end
  end

  describe "conversation header reconciliation (#401 item 2)" do
    test "the status badge and buttons track stage events", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id, status: "pending")

      {:ok, view, html} = live(conn, ~p"/conversations/#{conv.id}")
      assert html =~ "pending"
      refute html =~ "phx-click=\"interrupt\""

      # The server's real sequence: write the row, then publish the stage
      # event. Pre-#401 the handler updated :events but never :conv, so the
      # badge said "pending" through the whole run and Interrupt never
      # appeared.
      {:ok, _} =
        Conversations.get_conversation(conv.id, user.id)
        |> Conversations.update_conversation(%{status: "running"})

      Conversations.publish_stage(conv.id, "turn", "started", %{})

      html = render(view)
      assert html =~ "running"
      assert html =~ "phx-click=\"interrupt\""
    end
  end

  describe "delete handlers on stale rows (#401 item 3)" do
    test "agents index survives deleting an already-deleted agent", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/agents")

      {:ok, _} = Agents.delete_agent(agent)

      html = render_click(view, "delete", %{"id" => agent.id})
      assert html =~ "may already be deleted"
      assert Process.alive?(view.pid)
    end

    test "environments index survives deleting an already-deleted environment",
         %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/environments")

      {:ok, _} = Environments.delete_environment(env)

      html = render_click(view, "delete", %{"id" => env.id})
      assert html =~ "may already be deleted"
      assert Process.alive?(view.pid)
    end

    test "vaults index survives deleting an already-deleted vault", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/vaults")

      {:ok, _} = Vaults.delete_vault(vault)

      html = render_click(view, "delete", %{"id" => vault.id})
      assert html =~ "may already be deleted"
      assert Process.alive?(view.pid)
    end

    test "conversation show survives deleting an already-deleted conversation",
         %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conv.id}")

      {:ok, _} = Conversations.delete_conversation(conv)

      # Pre-#401 this deleted the mount-time struct: StaleEntryError, dead
      # LiveView, reconnect loop. Now: already gone is success.
      assert {:error, {:live_redirect, %{to: "/conversations"}}} =
               render_click(view, "delete", %{})
    end

    test "admin actions flash instead of crashing on a deleted user", %{conn: conn} do
      admin = insert_verified_user(role: "admin")
      victim = insert_verified_user()
      conn = login_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/admin")

      {:ok, _} = Fountain.Repo.delete(victim)

      html = render_click(view, "toggle_admin", %{"id" => victim.id})
      assert html =~ "may have been deleted"
      assert Process.alive?(view.pid)
    end
  end

  describe "mid-session refusal flashes (#401 item 5)" do
    test "a lapsed subscription shows a real message, not a raw atom",
         %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id, status: "idle")

      {:ok, view, _html} = live(conn, ~p"/conversations/#{conv.id}")

      stub(Fountain.Conversations.ConversationServer, :send_prompt, fn _id, _p, _i ->
        {:error, :subscription_required}
      end)

      render_click(view, "send_prompt", %{"prompt" => "hello"})

      flash = assert_redirect(view, "/account/billing")
      refute inspect(flash) =~ ":subscription_required"
    end
  end

  describe "idle badge (#401 item 6)" do
    test "idle renders with the healthy colour, not the unknown-value grey" do
      html = render_component(&FountainWeb.CoreComponents.badge/1, status: "idle")
      assert html =~ "status-ready-bg"

      unknown = render_component(&FountainWeb.CoreComponents.badge/1, status: "wat")
      refute unknown =~ "status-ready-bg"
    end
  end
end
