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
    test "returns 200 with the agent for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
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

    test "returns 422 when a skill entry has neither content nor source", %{
      conn: conn,
      raw_key: raw_key
    } do
      # OpenApiSpex does not enforce the content/source mutual-exclusivity rule;
      # the Ecto changeset's validate_skills/1 does, so this reaches the DB layer
      # as a pure changeset error and is rendered as 422.
      payload = %{
        name: "test-bot",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        skills: [%{name: "my-skill"}]
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      assert json_response(conn, 422)
    end

    test "returns 422 when environment_id belongs to another tenant", %{
      conn: conn,
      raw_key: raw_key
    } do
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)

      payload = %{
        name: "probe",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        environment_id: victim_env.id
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 422)
      assert body["errors"]["environment_id"] == ["does not exist"]
    end

    test "accepts environment_id owned by the caller", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      payload = %{
        name: "with-env",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        environment_id: env.id
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 201)
      assert body["data"]["environment_id"] == env.id
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

    test "returns 422 when updating environment_id to another tenant's", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{agent.id}", %{environment_id: victim_env.id})

      body = json_response(conn, 422)
      assert body["errors"]["environment_id"] == ["does not exist"]
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
