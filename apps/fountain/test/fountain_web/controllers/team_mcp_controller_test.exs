defmodule FountainWeb.TeamMcpControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Team

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, name: "team-lead")

    conv =
      insert_conversation(%{
        user_id: user.id,
        agent: agent,
        status: "idle",
        channel_id: Team.channel()
      })

    {:ok, user: user, raw_key: raw_key, conv: conv, agent: agent}
  end

  test "serves tools/list for the caller's team conversation", %{
    conn: conn,
    raw_key: key,
    conv: conv
  } do
    body =
      conn
      |> authed_with_key(key)
      |> post_json("/api/mcp/team/#{conv.id}", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })
      |> json_response(200)

    assert Enum.map(body["result"]["tools"], & &1["name"]) |> Enum.member?("send_to_teammate")
  end

  test "a conversation off the team channel, or another tenant's, gets 404", %{
    conn: conn,
    raw_key: key,
    user: user,
    agent: agent
  } do
    plain = insert_conversation(%{user_id: user.id, agent: agent, status: "idle"})

    conn
    |> authed_with_key(key)
    |> post_json("/api/mcp/team/#{plain.id}", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list"
    })
    |> json_response(404)

    other = insert_verified_user()
    {_k, other_key} = insert_api_key(other)

    conn
    |> authed_with_key(other_key)
    |> post_json("/api/mcp/team/#{plain.id}", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list"
    })
    |> json_response(404)
  end

  test "a notification gets 202 and no body", %{conn: conn, raw_key: key, conv: conv} do
    conn
    |> authed_with_key(key)
    |> post_json("/api/mcp/team/#{conv.id}", %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })
    |> response(202)
  end
end
