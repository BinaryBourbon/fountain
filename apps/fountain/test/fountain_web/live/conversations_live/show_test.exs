defmodule FountainWeb.ConversationsLive.ShowTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "restore_view_mode" do
    setup do
      user = insert_verified_user()
      conversation = insert_conversation(user_id: user.id)
      %{user: user, conversation: conversation}
    end

    @tag :restore_view_mode
    test "restores chat mode from client", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")
      # default is :pretty
      assert view |> element("[data-view-mode]") |> render() =~ "pretty"

      view |> render_hook("restore_view_mode", %{"mode" => "chat"})

      assert view |> element("[data-view-mode]") |> render() =~ "chat"
    end

    @tag :restore_view_mode
    test "restores raw mode from client", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      view |> render_hook("restore_view_mode", %{"mode" => "raw"})

      assert view |> element("[data-view-mode]") |> render() =~ "raw"
    end

    @tag :restore_view_mode
    test "ignores unrecognised mode value", %{conn: conn, user: user, conversation: conversation} do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      view |> render_hook("restore_view_mode", %{"mode" => "garbage"})

      # should stay on default :pretty
      assert view |> element("[data-view-mode]") |> render() =~ "pretty"
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
