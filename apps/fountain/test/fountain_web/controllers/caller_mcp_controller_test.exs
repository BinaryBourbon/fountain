defmodule FountainWeb.CallerMcpControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer

  @tools [
    %{
      "name" => "lookup_order",
      "description" => "Find an order",
      "parameters" => %{"type" => "object"}
    }
  ]

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, name: "pr-reviewer")

    conv =
      insert_conversation(%{
        user_id: user.id,
        agent: agent,
        status: "running",
        channel_id: "openai:t1",
        caller_tools: @tools
      })

    {:ok, user: user, raw_key: raw_key, conv: conv, agent: agent}
  end

  defp rpc(conn, key, conv_id, method, params \\ %{}) do
    conn
    |> authed_with_key(key)
    |> post_json("/api/mcp/caller/#{conv_id}", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
  end

  test "tools/list is exactly the conversation's registered tools, plus the wait tool", %{
    conn: conn,
    raw_key: key,
    conv: conv
  } do
    body = conn |> rpc(key, conv.id, "tools/list") |> json_response(200)

    assert Enum.map(body["result"]["tools"], & &1["name"]) ==
             ["lookup_order", "wait_for_caller_result"]
  end

  test "a conversation without caller tools, or another tenant's, gets 404", %{
    conn: conn,
    raw_key: key,
    user: user,
    agent: agent,
    conv: conv
  } do
    plain = insert_conversation(%{user_id: user.id, agent: agent, status: "idle"})
    conn |> rpc(key, plain.id, "tools/list") |> json_response(404)

    other = insert_verified_user()
    {_k, other_key} = insert_api_key(other)
    build_conn() |> rpc(other_key, conv.id, "tools/list") |> json_response(404)

    build_conn() |> rpc(key, "not-a-uuid", "tools/list") |> json_response(404)
  end

  test "tools/call parks the call on the server and returns the caller's answer", %{
    conn: conn,
    raw_key: key,
    conv: conv
  } do
    expect(ConversationServer, :park_caller_tool, fn conv_id, name, args, waiter ->
      assert conv_id == conv.id
      assert name == "lookup_order"
      assert args == %{"id" => "A-17"}
      send(waiter, {:caller_tool_result, "call_1", {:ok, "shipped"}})
      {:ok, "call_1"}
    end)

    body =
      conn
      |> rpc(key, conv.id, "tools/call", %{
        "name" => "lookup_order",
        "arguments" => %{"id" => "A-17"}
      })
      |> json_response(200)

    assert body["result"] == %{
             "content" => [%{"type" => "text", "text" => "shipped"}],
             "isError" => false
           }
  end

  test "an unanswered call comes back pending with its id, and the wait tool picks it up", %{
    conn: conn,
    raw_key: key,
    conv: conv
  } do
    expect(ConversationServer, :park_caller_tool, fn _conv_id, _name, _args, _waiter ->
      {:ok, "call_2"}
    end)

    body =
      conn
      |> rpc(key, conv.id, "tools/call", %{
        "name" => "lookup_order",
        "arguments" => %{"id" => "B", "timeout_seconds" => 1}
      })
      |> json_response(200)

    assert [%{"text" => text}] = body["result"]["content"]
    assert %{"pending" => true, "call_id" => "call_2"} = Jason.decode!(text)

    expect(ConversationServer, :await_caller_tool, fn _conv_id, "call_2", _waiter ->
      {:ok, {:ok, "late but here"}}
    end)

    body =
      build_conn()
      |> rpc(key, conv.id, "tools/call", %{
        "name" => "wait_for_caller_result",
        "arguments" => %{"call_id" => "call_2"}
      })
      |> json_response(200)

    assert body["result"]["content"] == [%{"type" => "text", "text" => "late but here"}]
  end

  test "an expired call is an error result to the agent", %{conn: conn, raw_key: key, conv: conv} do
    expect(ConversationServer, :await_caller_tool, fn _conv_id, "call_3", _waiter ->
      {:ok, {:error, "the caller did not answer within the deadline"}}
    end)

    body =
      conn
      |> rpc(key, conv.id, "tools/call", %{
        "name" => "wait_for_caller_result",
        "arguments" => %{"call_id" => "call_3"}
      })
      |> json_response(200)

    assert body["result"]["isError"] == true

    assert [%{"text" => "the caller did not answer within the deadline"}] =
             body["result"]["content"]
  end

  test "no server, no turn", %{conn: conn, raw_key: key, conv: conv} do
    expect(ConversationServer, :park_caller_tool, fn _, _, _, _ -> {:error, :no_turn} end)

    body =
      conn
      |> rpc(key, conv.id, "tools/call", %{"name" => "lookup_order", "arguments" => %{}})
      |> json_response(200)

    assert body["result"]["isError"] == true
  end

  test "a notification gets 202 and no body", %{conn: conn, raw_key: key, conv: conv} do
    conn
    |> authed_with_key(key)
    |> post_json("/api/mcp/caller/#{conv.id}", %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })
    |> response(202)
  end
end
