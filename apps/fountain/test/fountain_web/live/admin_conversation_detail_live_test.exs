defmodule FountainWeb.AdminConversationDetailLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Fountain.Accounts
  alias Fountain.Audit.AdminEvent
  alias Fountain.Repo

  defp insert_admin(overrides \\ %{}) do
    user = insert_verified_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "access control" do
    test "regular user is redirected away — even from their own conversation", %{conn: conn} do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin/conversations/#{conv.id}")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      conv = insert_conversation()
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/conversations/#{conv.id}")
      assert path =~ "/auth/login"
    end
  end

  describe "cross-tenant read" do
    test "admin can view another tenant's conversation metadata", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()
      conv = insert_conversation(user_id: target.id, status: "running")
      insert_turn(conv, %{status: "completed", exit_code: 0})

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/conversations/#{conv.id}")

      assert html =~ String.slice(conv.id, 0, 8)
      assert html =~ target.email
      assert html =~ "running"
      # owner links back to the user detail page
      assert html =~ ~p"/admin/users/#{target.id}"
    end

    test "prompt and log content never render — metadata only", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()
      conv = insert_conversation(user_id: target.id)
      insert_turn(conv, %{prompt: "TENANT_PRIVATE_PROMPT_a8f3"})
      insert_log_event(conv, %{data: "TENANT_PRIVATE_OUTPUT_c61b"})

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/conversations/#{conv.id}")

      refute html =~ "TENANT_PRIVATE_PROMPT_a8f3"
      refute html =~ "TENANT_PRIVATE_OUTPUT_c61b"
      # but the turn's existence and the log volume are visible
      assert html =~ "1 turns · 1 log events"
    end

    test "records an admin.conversation.viewed audit event on visit", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()
      conv = insert_conversation(user_id: target.id)

      conn = login_user(conn, admin)
      {:ok, _lv, _html} = live(conn, ~p"/admin/conversations/#{conv.id}")

      assert [event] =
               Repo.all(from e in AdminEvent, where: e.event_type == "admin.conversation.viewed")

      assert event.actor_user_id == admin.id
      assert event.target_user_id == target.id
      assert event.metadata["conversation_id"] == conv.id
    end

    test "unknown conversation id redirects back to /admin", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               live(conn, ~p"/admin/conversations/#{Ecto.UUID.generate()}")
    end
  end
end
