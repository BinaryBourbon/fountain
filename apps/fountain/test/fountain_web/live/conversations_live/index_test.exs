defmodule FountainWeb.ConversationsLive.IndexTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "roots filter" do
    setup do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      %{user: user, root: root, child: child}
    end

    test "shows all conversations by default", %{conn: conn, user: user, root: root, child: child} do
      conn = login_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/conversations")

      assert html =~ short(root.id)
      assert html =~ short(child.id)
    end

    test "shows only roots when preference is already true", %{conn: conn, user: user, root: root, child: child} do
      {:ok, _} = Fountain.Accounts.update_preferences(user, %{conversations_roots_only: true})
      # Reload user from DB so session has current preference
      user = Fountain.Accounts.get_user!(user.id)

      conn = login_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/conversations")

      assert html =~ short(root.id)
      refute html =~ short(child.id)
    end

    test "toggle_roots_only hides child conversations and persists preference",
         %{conn: conn, user: user, root: root, child: child} do
      conn = login_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/conversations")

      # Both visible initially
      assert html =~ short(root.id)
      assert html =~ short(child.id)

      # Toggle to roots only
      render_click(view, "toggle_roots_only")
      html = render(view)

      assert html =~ short(root.id)
      refute html =~ short(child.id)

      # Preference was persisted
      reloaded = Fountain.Accounts.get_user!(user.id)
      assert reloaded.conversations_roots_only == true
    end

    test "toggle_roots_only back to all shows child again",
         %{conn: conn, user: user, root: root, child: child} do
      {:ok, _} = Fountain.Accounts.update_preferences(user, %{conversations_roots_only: true})
      user = Fountain.Accounts.get_user!(user.id)

      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/conversations")

      render_click(view, "toggle_roots_only")
      html = render(view)

      assert html =~ short(root.id)
      assert html =~ short(child.id)

      reloaded = Fountain.Accounts.get_user!(user.id)
      assert reloaded.conversations_roots_only == false
    end
  end

  defp short(id), do: binary_part(id, 0, 8)
end
