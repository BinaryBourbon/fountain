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
end
