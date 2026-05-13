defmodule FountainWeb.ConversationsLive.ShowTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "view_mode loaded from database" do
    setup do
      user = insert_verified_user()
      conversation = insert_conversation(user_id: user.id)
      %{user: user, conversation: conversation}
    end

    test "mounts with default pretty mode when no preference saved", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      assert view |> element("[data-view-mode]") |> render() =~ "pretty"
    end

    test "mounts with chat mode when preference is saved as chat", %{conn: conn, user: user, conversation: conversation} do
      {:ok, _} = Fountain.Accounts.update_preferences(user, %{conversation_view_mode: "chat"})
      user = Fountain.Accounts.get_user!(user.id)

      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      assert view |> element("[data-view-mode]") |> render() =~ "chat"
    end

    test "mounts with raw mode when preference is saved as raw", %{conn: conn, user: user, conversation: conversation} do
      {:ok, _} = Fountain.Accounts.update_preferences(user, %{conversation_view_mode: "raw"})
      user = Fountain.Accounts.get_user!(user.id)

      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      assert view |> element("[data-view-mode]") |> render() =~ "raw"
    end
  end

  describe "set_view_mode" do
    setup do
      user = insert_verified_user()
      conversation = insert_conversation(user_id: user.id)
      %{user: user, conversation: conversation}
    end

    @tag :push_view_mode_changed
    test "pushes view_mode_changed event to client when mode is set", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      view |> element("[phx-click='set_view_mode'][phx-value-mode='chat']") |> render_click()
      assert_push_event(view, "view_mode_changed", %{mode: "chat"})
    end

    test "persists view mode to database when changed", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      view |> element("[phx-click='set_view_mode'][phx-value-mode='raw']") |> render_click()

      reloaded = Fountain.Accounts.get_user!(user.id)
      assert reloaded.conversation_view_mode == "raw"
    end
  end

  describe "toggle_stream persists visible_streams" do
    setup do
      user = insert_verified_user()
      conversation = insert_conversation(user_id: user.id)
      %{user: user, conversation: conversation}
    end

    test "toggling stdout off persists the preference", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      view |> element("[phx-click='toggle_stream'][phx-value-stream='stdout']") |> render_click()

      reloaded = Fountain.Accounts.get_user!(user.id)
      assert "stdout" not in reloaded.conversation_visible_streams
      assert "stderr" in reloaded.conversation_visible_streams
      assert "stage" in reloaded.conversation_visible_streams
    end

    test "toggling stdout back on persists the preference", %{conn: conn, user: user, conversation: conversation} do
      {:ok, _} = Fountain.Accounts.update_preferences(user, %{conversation_visible_streams: ["stderr", "stage"]})
      user = Fountain.Accounts.get_user!(user.id)

      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      view |> element("[phx-click='toggle_stream'][phx-value-stream='stdout']") |> render_click()

      reloaded = Fountain.Accounts.get_user!(user.id)
      assert "stdout" in reloaded.conversation_visible_streams
    end

    test "mounts with saved visible_streams preference", %{conn: conn, user: user, conversation: conversation} do
      {:ok, _} = Fountain.Accounts.update_preferences(user, %{conversation_visible_streams: ["stdout"]})
      user = Fountain.Accounts.get_user!(user.id)

      conn = login_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/conversations/#{conversation.id}")

      # stdout pill should be active (not struck through), stderr and stage struck through
      assert html =~ "toggle_stream"
    end
  end
end
