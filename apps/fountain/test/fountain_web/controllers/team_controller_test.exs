defmodule FountainWeb.TeamControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Audit, Repo, Team}
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp inert_start_child do
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "GET /api/team" do
    test "lists the roster with name, presence, preview and unread", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, title: "Ada (staging)")
      insert_turn(conv, prompt: "hello there", status: "completed")
      # Someone else's team is not ours; an unbound conversation is not a teammate.
      insert_teammate_conv(insert_verified_user(), insert_agent())
      insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

      body = conn |> authed_with_key(key) |> get("/api/team") |> json_response(200)

      assert [entry] = body["data"]
      assert entry["agent_id"] == ada.id
      assert entry["name"] == "Ada (staging)"
      assert entry["agent"]["name"] == "Ada"
      assert entry["conversation"]["id"] == conv.id
      assert entry["conversation"]["channel_id"] == "fountain:team"
      assert entry["presence"]["state"] == "away"
      assert entry["preview"] == %{"kind" => "you", "text" => "hello there"}
      assert entry["last_turn"]["prompt"] == "hello there"
      assert is_boolean(entry["unread"])
    end

    test "is empty with no team", %{conn: conn, raw_key: key} do
      assert %{"data" => []} =
               conn |> authed_with_key(key) |> get("/api/team") |> json_response(200)
    end

    test "401 without a key", %{conn: conn} do
      assert conn |> get("/api/team") |> json_response(401)
    end
  end

  describe "GET /api/team/:agent_id" do
    test "one teammate, or 404 when the agent is not on the team", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada)
      loner = insert_agent(user_id: user.id)

      assert %{"data" => %{"agent_id" => id}} =
               conn |> authed_with_key(key) |> get("/api/team/#{ada.id}") |> json_response(200)

      assert id == ada.id
      assert conn |> authed_with_key(key) |> get("/api/team/#{loner.id}") |> json_response(404)
    end
  end

  describe "POST /api/team" do
    test "adds the agent with a name, environment and vault; 201 with the teammate", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      env = insert_env(user_id: user.id, name: "staging")
      vault = insert_vault(user_id: user.id)
      inert_start_child()

      resp =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team", %{
          agent_id: ada.id,
          name: "Ada (staging)",
          environment_id: env.id,
          vault_id: vault.id
        })

      body = json_response(resp, 201)
      assert body["data"]["name"] == "Ada (staging)"
      assert body["data"]["conversation"]["environment_id"] == env.id
      assert body["data"]["conversation"]["vault_id"] == vault.id
      assert body["data"]["conversation"]["source"] == "api"

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "team.member.added" in actions
    end

    test "200 when the agent is already on the team", %{conn: conn, user: user, raw_key: key} do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team", %{agent_id: ada.id, name: "ignored"})
        |> json_response(200)

      assert body["data"]["conversation"]["id"] == conv.id
      assert body["data"]["name"] == "Ada"
    end

    test "404 for another tenant's agent, environment or vault", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      other = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> post_json("/api/team", %{agent_id: insert_agent(user_id: other.id).id})
             |> json_response(404)

      assert %{"error" => "environment_not_found"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team", %{
                 agent_id: ada.id,
                 environment_id: insert_env(user_id: other.id).id
               })
               |> json_response(404)

      assert %{"error" => "vault_not_found"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team", %{
                 agent_id: ada.id,
                 vault_id: insert_vault(user_id: other.id).id
               })
               |> json_response(404)
    end

    test "422 when the agent's allowlist forbids the environment", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      env = insert_env(user_id: user.id)
      ada = insert_agent(user_id: user.id, allowed_environment_ids: [])

      assert %{"error" => "environment_not_allowed"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team", %{agent_id: ada.id, environment_id: env.id})
               |> json_response(422)

      assert Team.list_teammates(user.id) == []
    end
  end

  describe "DELETE /api/team/:agent_id" do
    test "removes the teammate; 404 when not on the team", %{conn: conn, user: user, raw_key: key} do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)

      resp = conn |> authed_with_key(key) |> delete("/api/team/#{ada.id}")
      assert response(resp, 204)
      assert Team.list_teammates(user.id) == []
      assert Repo.reload(conv).channel_id == nil

      assert conn |> authed_with_key(key) |> delete("/api/team/#{ada.id}") |> json_response(404)
    end
  end

  describe "POST /api/team/:agent_id/messages" do
    test "hands the prompt to the conversation server; 202 with the conversation", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn id, text, images, opts ->
        send(test_pid, {:sent, id, text, images, opts[:actor]})
        :ok
      end)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/messages", %{prompt: "hello"})
        |> json_response(202)

      assert body == %{"status" => "queued", "conversation_id" => conv.id}
      conv_id = conv.id
      assert_received {:sent, ^conv_id, "hello", [], "api"}
    end

    test "400 conversation_busy while the teammate is busy, 404 when not on the team", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada, status: "running")
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)

      assert %{"error" => "conversation_busy"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team/#{ada.id}/messages", %{prompt: "hurry"})
               |> json_response(400)

      loner = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> post_json("/api/team/#{loner.id}/messages", %{prompt: "hi"})
             |> json_response(404)
    end

    test "a terminated teammate gets a fresh conversation, named in the response", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      dead = insert_teammate_conv(user, ada, status: "terminated", title: "Ada (staging)")
      inert_start_child()

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/messages", %{prompt: "are you there?"})
        |> json_response(202)

      refute body["conversation_id"] == dead.id
      assert [%{conversation: %{id: id}, name: "Ada (staging)"}] = Team.list_teammates(user.id)
      assert id == body["conversation_id"]
    end
  end
end
