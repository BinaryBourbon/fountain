defmodule FountainWeb.TeamScheduleControllerTest do
  @moduledoc """
  Team schedules over the API (#825): `/api/team/schedules` and
  `/api/team/:agent_id/schedules[/:id[/run]]`, tenant-scoped, audited with
  the request's attribution, broadcasting `schedule` on the team topic.
  """
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Audit, Team}
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Team.Schedules

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, name: "Ada")
    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp create!(user, agent, overrides \\ %{}) do
    {:ok, s} =
      Schedules.create_schedule(
        user.id,
        Map.merge(
          %{"agent_id" => agent.id, "cron" => "0 9 * * *", "prompt" => "standup please"},
          Map.new(overrides)
        )
      )

    s
  end

  defp schedule_events(user_id) do
    user_id
    |> Audit.list_recent_for_user()
    |> Enum.filter(&String.starts_with?(&1.action, "team.schedule."))
  end

  describe "GET /api/team/schedules" do
    test "lists every schedule of the caller across teammates, never another tenant's", %{
      conn: conn,
      user: user,
      raw_key: key,
      agent: ada
    } do
      linus = insert_agent(user_id: user.id, name: "Linus")
      a = create!(user, ada, %{"name" => "Standup"})
      b = create!(user, linus, %{"cron" => "0 18 * * *"})
      other = insert_verified_user()
      create!(other, insert_agent(user_id: other.id))

      body = conn |> authed_with_key(key) |> get("/api/team/schedules") |> json_response(200)

      assert body["data"] |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([a.id, b.id])
      entry = Enum.find(body["data"], &(&1["id"] == a.id))
      assert entry["agent_id"] == ada.id
      assert entry["name"] == "Standup"
      assert entry["cron"] == "0 9 * * *"
      assert entry["prompt"] == "standup please"
      assert entry["one_off"] == false
      assert entry["enabled"] == true
      assert is_binary(entry["next_run_at"])
      assert entry["last_run_at"] == nil
      assert entry["last_error"] == nil
    end

    test "401 without a key", %{conn: conn} do
      assert conn |> get("/api/team/schedules") |> json_response(401)
    end
  end

  describe "GET /api/team/:agent_id/schedules" do
    test "one teammate's schedules only", %{conn: conn, user: user, raw_key: key, agent: ada} do
      linus = insert_agent(user_id: user.id, name: "Linus")
      a = create!(user, ada)
      create!(user, linus)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/team/#{ada.id}/schedules")
        |> json_response(200)

      assert [%{"id" => id}] = body["data"]
      assert id == a.id
    end
  end

  describe "POST /api/team/:agent_id/schedules" do
    test "creates with the request's attribution; 201 with the schedule", %{
      conn: conn,
      user: user,
      raw_key: key,
      agent: ada
    } do
      Team.subscribe(user.id)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/schedules", %{
          name: "Standup",
          cron: "0 9 * * 1-5",
          prompt: "What's on today?",
          one_off: true
        })
        |> json_response(201)

      assert %{"id" => id, "agent_id" => agent_id, "one_off" => true, "enabled" => true} =
               body["data"]

      assert agent_id == ada.id
      assert %{name: "Standup", cron: "0 9 * * 1-5"} = Schedules.get_schedule(id, user.id)
      assert_receive {:team_schedules_changed, _}

      assert [%{action: "team.schedule.created", actor: "api"} = ev] = schedule_events(user.id)
      assert ev.metadata["prompt_bytes"] == byte_size("What's on today?")
      refute Map.has_key?(ev.metadata, "prompt")
    end

    test "422 with errors on a bad cron; 404 for another tenant's agent", %{
      conn: conn,
      raw_key: key,
      agent: ada
    } do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/schedules", %{cron: "not a cron", prompt: "x"})
        |> json_response(422)

      assert body["errors"]["cron"]

      foreign = insert_agent(user_id: insert_verified_user().id)

      assert conn
             |> authed_with_key(key)
             |> post_json("/api/team/#{foreign.id}/schedules", %{cron: "0 9 * * *", prompt: "x"})
             |> json_response(404)
    end
  end

  describe "GET/PATCH/DELETE /api/team/:agent_id/schedules/:id" do
    test "show, update and delete, scoped to the tenant and the path's agent", %{
      conn: conn,
      user: user,
      raw_key: key,
      agent: ada
    } do
      s = create!(user, ada)
      linus = insert_agent(user_id: user.id, name: "Linus")
      path = "/api/team/#{ada.id}/schedules/#{s.id}"

      assert %{"data" => %{"id" => id}} =
               conn |> authed_with_key(key) |> get(path) |> json_response(200)

      assert id == s.id

      # The same row under another agent's path is not found.
      assert conn
             |> authed_with_key(key)
             |> get("/api/team/#{linus.id}/schedules/#{s.id}")
             |> json_response(404)

      # Another tenant cannot see it at all.
      {_k, other_key} = insert_api_key(insert_verified_user())
      assert conn |> authed_with_key(other_key) |> get(path) |> json_response(404)

      body =
        conn
        |> authed_with_key(key)
        |> patch_json(path, %{enabled: false, name: "Paused"})
        |> json_response(200)

      assert body["data"]["enabled"] == false
      assert body["data"]["name"] == "Paused"

      assert %{actor: "api"} =
               Enum.find(schedule_events(user.id), &(&1.action == "team.schedule.updated"))

      assert conn |> authed_with_key(key) |> delete(path) |> response(204)
      assert Schedules.get_schedule(s.id, user.id) == nil
      assert Enum.any?(schedule_events(user.id), &(&1.action == "team.schedule.deleted"))
      assert conn |> authed_with_key(key) |> get(path) |> json_response(404)
    end

    test "422 on an invalid update", %{conn: conn, user: user, raw_key: key, agent: ada} do
      s = create!(user, ada)

      body =
        conn
        |> authed_with_key(key)
        |> patch_json("/api/team/#{ada.id}/schedules/#{s.id}", %{cron: "@reboot"})
        |> json_response(422)

      assert body["errors"]["cron"]
    end
  end

  describe "POST /api/team/:agent_id/schedules/:id/run" do
    test "runs now through the teammate's thread; 202 with the conversation", %{
      conn: conn,
      user: user,
      raw_key: key,
      agent: ada
    } do
      conv = insert_teammate_conv(user, ada)
      s = create!(user, ada, %{"prompt" => "standup please"})
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn id, text, _images, opts ->
        send(test_pid, {:sent, id, text, opts[:actor]})
        :ok
      end)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/schedules/#{s.id}/run", %{})
        |> json_response(202)

      assert body == %{"status" => "queued", "conversation_id" => conv.id}
      assert_received {:sent, conv_id, "standup please", "api"}
      assert conv_id == conv.id

      s = Schedules.get_schedule(s.id, user.id)
      assert %DateTime{} = s.last_run_at
      assert s.last_conversation_id == conv.id
      assert Enum.any?(schedule_events(user.id), &(&1.action == "team.schedule.fired"))
    end

    test "400 conversation_busy while a turn is running; 404 off the team", %{
      conn: conn,
      user: user,
      raw_key: key,
      agent: ada
    } do
      insert_teammate_conv(user, ada, status: "running")
      s = create!(user, ada)
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)

      assert %{"error" => "conversation_busy"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team/#{ada.id}/schedules/#{s.id}/run", %{})
               |> json_response(400)

      assert Schedules.get_schedule(s.id, user.id).last_error == "teammate was busy"

      loner = insert_agent(user_id: user.id, name: "Loner")
      s2 = create!(user, loner)

      assert conn
             |> authed_with_key(key)
             |> post_json("/api/team/#{loner.id}/schedules/#{s2.id}/run", %{})
             |> json_response(404)
    end
  end
end
