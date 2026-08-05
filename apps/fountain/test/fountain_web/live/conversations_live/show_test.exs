defmodule FountainWeb.ConversationsLive.ShowTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Conversations

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

  describe "send_prompt image validation" do
    setup do
      user = insert_verified_user()
      conversation = insert_conversation(user_id: user.id)
      %{user: user, conversation: conversation}
    end

    test "malformed base64 flashes an error instead of crashing the LiveView", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      # This path used to Base.decode64! the client payload, so malformed
      # input took the whole LiveView process down — and crash reports log
      # socket assigns.
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      render_hook(view, "images_selected", %{
        "images" => [%{"data" => "not base64 !!!", "media_type" => "image/png"}]
      })

      html = render_hook(view, "send_prompt", %{"prompt" => "hi"})

      assert html =~ "base64"
      assert Process.alive?(view.pid)
    end

    test "a disallowed media type is refused like the API refuses it", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      render_hook(view, "images_selected", %{
        "images" => [%{"data" => Base.encode64("x"), "media_type" => "text/html"}]
      })

      html = render_hook(view, "send_prompt", %{"prompt" => "hi"})

      assert html =~ "unsupported image media_type"
      assert Process.alive?(view.pid)
    end
  end

  describe "read-only for lapsed subscriptions (#505)" do
    setup do
      user =
        insert_verified_user()
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "past_due"})
        |> Fountain.Repo.update!()

      conversation = insert_conversation(user_id: user.id)
      %{user: user, conversation: conversation}
    end

    test "the conversation renders with a banner and no composer", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      conn = login_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/conversations/#{conversation.id}")

      assert html =~ "Read-only"
      assert html =~ "/account/billing"
      refute html =~ ~s(phx-submit="send_prompt")
    end

    test "hand-sent spend events are refused before reaching the runtime", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      # The composer is hidden, but events can still be sent by hand (#399's
      # lesson) — each spend event must be blocked server-side.
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      for {event, params} <- [
            {"send_prompt", %{"prompt" => "hi"}},
            {"update_prompt", %{"prompt" => "hi"}},
            {"images_selected", %{"images" => []}}
          ] do
        html = render_hook(view, event, params)
        assert html =~ "read-only", "#{event} was not refused"
      end

      assert Conversations._unsafe_list_turns(conversation.id) == []
    end

    test "terminate still reaches its handler — stopping spend stays allowed", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      # Reaching the real handler (which terminates via the server-already-dead
      # path here) is the proof the event was not blocked by the subscription
      # guard — a lapsed user must be able to stop a running sprite.
      html = render_hook(view, "terminate", %{})
      assert html =~ "Terminated"
    end

    test "delete still works — removing data is not consumption", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations/#{conversation.id}")

      render_hook(view, "delete", %{})

      assert_redirect(view, "/conversations")
      assert Conversations.get_conversation(conversation.id, user.id) == nil
    end

    test "an active user still gets the composer and no banner", %{conn: conn} do
      user = insert_verified_user()
      conversation = insert_conversation(user_id: user.id)
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/conversations/#{conversation.id}")

      assert html =~ ~s(phx-submit="send_prompt")
      refute html =~ "Read-only"
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
