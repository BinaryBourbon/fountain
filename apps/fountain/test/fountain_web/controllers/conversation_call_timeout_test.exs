defmodule FountainWeb.ConversationCallTimeoutTest do
  # async: false — registers a process in the global Horde registry under the
  # conversation id and lowers the global call-timeout app env.
  use FountainWeb.ConnCase, async: false

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Repo

  # Regression tests for #412: a GenServer.call timeout EXITS rather than
  # returning an error, and no controller or LiveView call site caught it.
  # A server stuck in handle_continue(:provision) blocks its mailbox, so
  # prompt/interrupt/terminate 500'd — and DELETE returned 500 with the row
  # silently kept, because `_ = ConversationServer.terminate_conversation(id)` discards a
  # return value, not an exit.

  setup %{conn: conn} do
    Application.put_env(:fountain, :conversation_call_timeout_ms, 150)
    on_exit(fn -> Application.delete_env(:fountain, :conversation_call_timeout_ms) end)

    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    conv = insert_conversation(user_id: user.id, status: "pending")

    # The shape of a server whose mailbox is blocked by provisioning:
    # registered under the conversation id, never answering calls.
    test_pid = self()

    stuck =
      spawn(fn ->
        Horde.Registry.register(Fountain.ConversationRegistry, conv.id, nil)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 2_000
    on_exit(fn -> Process.exit(stuck, :kill) end)

    {:ok, conn: authed_with_key(conn, raw_key), user: user, conv: conv}
  end

  test "a prompt during provisioning returns a durable queued receipt",
       %{conn: conn, conv: conv} do
    conn = post_json(conn, "/api/conversations/#{conv.id}/prompts", %{prompt: "hi"})

    body = json_response(conn, 200)
    assert body["status"] == "queued"
    assert Repo.get!(Fountain.Conversations.Turn, body["turn_id"]).status == "pending"
    receipt = Repo.get!(Fountain.Conversations.PromptReceipt, body["receipt_id"])
    assert receipt.turn_id == body["turn_id"]
  end

  test "interrupt during provisioning returns 503, not a 500", %{conn: conn, conv: conv} do
    conn = post(conn, "/api/conversations/#{conv.id}/interrupt")

    assert %{"error" => "provisioning"} = json_response(conn, 503)
  end

  test "terminate during provisioning returns 503, not a 500", %{conn: conn, conv: conv} do
    conn = post(conn, "/api/conversations/#{conv.id}/terminate")

    assert %{"error" => "provisioning"} = json_response(conn, 503)
  end

  test "DELETE still deletes the row when the server does not answer",
       %{conn: conn, conv: conv} do
    # The worst pre-#412 case: the terminate exit blew through
    # delete_conversation/1 before Repo.delete ran, so the DELETE 500'd and
    # the row silently survived.
    conn = delete(conn, "/api/conversations/#{conv.id}")

    assert conn.status == 204
    assert Repo.get(Fountain.Conversations.Conversation, conv.id) == nil
  end

  test "accepted intent can be cancelled while the actor mailbox remains blocked", %{
    conv: conv,
    user: user
  } do
    assert :ok = ConversationServer.send_prompt(conv.id, "hi", [])
    receipt = Fountain.Conversations.PromptDelivery.queued(user.id, conv.id)
    assert :ok = ConversationServer.interrupt(conv.id)
    assert Repo.reload!(receipt).failure_reason == "cancelled"
    assert Repo.get!(Fountain.Conversations.Turn, receipt.turn_id).status == "failed"
    assert {:error, :provisioning} = ConversationServer.terminate_conversation(conv.id)
  end
end
