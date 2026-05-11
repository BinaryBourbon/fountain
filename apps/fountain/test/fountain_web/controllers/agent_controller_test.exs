defmodule FountainWeb.AgentControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/agents" do
    test "returns 200 and lists user's agents", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert agent.id in ids
    end

    test "does not include agents belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_agent.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/agents")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/agents/:id" do
    test "returns 200 with the agent for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == agent.id
      assert body["data"]["name"] == agent.name
    end

    test "returns 404 when the agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{other_agent.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conn = get(conn, "/api/agents/#{agent.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/agents" do
    test "creates an agent and returns 201", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "test-bot", model: "anthropic/claude-sonnet-4-6", runtime: "claude"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 201)
      assert body["data"]["name"] == "test-bot"
      assert body["data"]["model"] == "anthropic/claude-sonnet-4-6"
      assert body["data"]["runtime"] == "claude"
      assert body["data"]["id"]
    end

    test "returns 401 without authentication", %{conn: conn} do
      payload = %{name: "test-bot", model: "anthropic/claude-sonnet-4-6", runtime: "claude"}
      conn = post_json(conn, "/api/agents", payload)
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/agents/:id" do
    test "updates the agent and returns 200", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{agent.id}", %{name: "updated-bot"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "updated-bot"
      assert body["data"]["id"] == agent.id
    end

    test "returns 404 when the agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{other_agent.id}", %{name: "hacked"})

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conn = put_json(conn, "/api/agents/#{agent.id}", %{name: "updated"})
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/agents/:id" do
    test "deletes the agent and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/agents/#{agent.id}")

      assert conn.status == 204
    end

    test "returns 404 when the agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/agents/#{other_agent.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conn = delete(conn, "/api/agents/#{agent.id}")
      assert json_response(conn, 401)
    end
  end
end
