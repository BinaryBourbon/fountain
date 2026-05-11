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
  end
end
