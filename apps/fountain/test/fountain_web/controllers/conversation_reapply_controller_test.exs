defmodule FountainWeb.ConversationReapplyControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    vault = insert_vault(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready", agent_id: agent.id)

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        vault_id: vault.id,
        runtime_session_id: "old-session",
        status: "idle"
      )

    {:ok, user: user, raw_key: raw_key, agent: agent, vault: vault, conv: conv}
  end

  test "POST /api/conversations/:id/reapply keeps the thread and clears explicit nulls", ctx do
    response =
      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> post_json("/api/conversations/#{ctx.conv.id}/reapply", %{"vault_id" => nil})
      |> json_response(200)
      |> Map.fetch!("data")

    assert response["id"] == ctx.conv.id
    assert response["agent_id"] == ctx.agent.id
    assert response["vault_id"] == nil
    assert response["sandbox_id"] == ctx.conv.sandbox_id

    # The machine survives, so the runtime session on its disk is still
    # resumable and the agent keeps its memory of this thread. The server
    # drops the connection, which is what makes the next turn spawn a runtime
    # that reads the new environment and the rewritten files.
    assert response["runtime_session_id"] == "old-session"

    [audit] =
      Fountain.Audit.list_for_user(ctx.user.id)
      |> Enum.filter(&(&1.action == "conversation.configuration_reapplied"))

    assert audit.actor == "api"
  end

  test "returns 404 for another tenant's conversation", ctx do
    other = insert_active_user()
    theirs = insert_conversation(user_id: other.id, status: "idle")

    assert %{"error" => "not_found"} =
             ctx.conn
             |> authed_with_key(ctx.raw_key)
             |> post_json("/api/conversations/#{theirs.id}/reapply", %{})
             |> json_response(404)
  end

  test "returns 409 and leaves a conversation with a running turn unchanged", ctx do
    insert_turn(ctx.conv, status: "running")

    assert %{"error" => "conversation_busy"} =
             ctx.conn
             |> authed_with_key(ctx.raw_key)
             |> post_json("/api/conversations/#{ctx.conv.id}/reapply", %{})
             |> json_response(409)

    assert Conversations._unsafe_get_conversation!(ctx.conv.id).runtime_session_id ==
             "old-session"
  end
end
