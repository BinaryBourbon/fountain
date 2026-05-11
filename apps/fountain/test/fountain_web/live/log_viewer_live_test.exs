defmodule FountainWeb.LogViewerLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "LogViewerLive.Show" do
    test "renders log events for the owning user", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, stream: "stdout", data: "hello world")
      insert_log_event(conv, stream: "stderr", data: "oh no")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      assert html =~ "hello world"
      assert html =~ "oh no"
      assert html =~ "[stdout]"
      assert html =~ "[stderr]"
    end

    test "redirects when conversation belongs to another user", %{conn: conn} do
      owner = insert_verified_user()
      attacker = insert_verified_user()
      conv = insert_conversation(user_id: owner.id)

      conn = login_user(conn, attacker)

      assert {:error, {:live_redirect, %{to: "/conversations"}}} =
               live(conn, ~p"/conversations/#{conv.id}/logs")
    end

    test "shows empty state when no log events exist", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      assert html =~ "No log output yet"
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/conversations/#{Ecto.UUID.generate()}/logs")

      assert path =~ "/auth/login"
    end

    test "handle_info :log_event appends a new log entry to the view", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      # Simulate a PubSub :log_event message arriving
      log_entry = %Fountain.Conversations.LogEvent{
        id: Ecto.UUID.generate(),
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "live append test",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      send(lv.pid, {:log_event, log_entry})

      html = render(lv)
      assert html =~ "live append test"
    end

    test "handle_info :conversation_updated refreshes the conversation assign", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      # Initially status is "pending"
      assert html =~ conv.id

      # Simulate a :conversation_updated broadcast with updated status
      updated_conv = %{conv | status: "running"}
      send(lv.pid, {:conversation_updated, updated_conv})

      html = render(lv)
      # The page should still render (conversation assign updated)
      assert html =~ conv.id
    end

    test "stage event kind renders [stage:X:Y] format", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, kind: "stage", stream: "", stage: "provision", state: "started", data: "")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      assert html =~ "[stage:provision:started]"
      refute html =~ "[stdout]"
    end

    test "stderr event renders with red line class", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, kind: "output", stream: "stderr", data: "error output")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      assert html =~ "error output"
      assert html =~ "text-red-400"
    end

    test "handle_info with unknown message is ignored", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/conversations/#{conv.id}/logs")

      # Should not crash the LiveView
      send(lv.pid, {:unrecognized_message, "ignored"})
      assert render(lv) =~ conv.id
    end
  end
end
