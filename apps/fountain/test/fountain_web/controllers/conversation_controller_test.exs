defmodule FountainWeb.ConversationControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer
  alias FountainWeb.ConversationController

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/conversations" do
    test "returns 200 and lists user's conversations", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert conv.id in ids
    end

    test "does not include conversations belonging to other users", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_conv.id in ids
    end

    test "filters by agent_id, channel_id and status (#832)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      ada = insert_agent(user_id: user.id)
      linus = insert_agent(user_id: user.id)

      team_idle =
        insert_conversation(
          user_id: user.id,
          agent: ada,
          channel_id: "fountain:team",
          status: "idle"
        )

      team_dead =
        insert_conversation(
          user_id: user.id,
          agent: ada,
          channel_id: "fountain:team",
          status: "terminated"
        )

      plain = insert_conversation(user_id: user.id, agent: linus, status: "idle")

      ids = fn query ->
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations", query)
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])
        |> Enum.sort()
      end

      assert ids.(agent_id: ada.id) == Enum.sort([team_idle.id, team_dead.id])
      assert ids.(channel_id: "fountain:team") == Enum.sort([team_idle.id, team_dead.id])
      assert ids.(agent_id: ada.id, status: "terminated") == [team_dead.id]
      assert ids.(status: "idle,terminated") == Enum.sort([team_idle.id, team_dead.id, plain.id])
      assert ids.(agent_id: linus.id, channel_id: "fountain:team") == []

      assert %{"error" => "invalid_status"} =
               conn
               |> authed_with_key(raw_key)
               |> get("/api/conversations", status: "terminted")
               |> json_response(400)
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/conversations")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:id" do
    test "returns 200 with the conversation for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == conv.id
    end

    # `fountain acp` asks before replaying a conversation an editor handed
    # back: a legacy-runtime conversation has a transcript, but not one stored
    # as protocol, so there is nothing a protocol client can render (#703).
    test "reports whether the runtime speaks ACP", %{conn: conn, user: user, raw_key: raw_key} do
      acp_agent = insert_agent(user_id: user.id, runtime: "claude")
      acp_conv = insert_conversation(user_id: user.id, agent_id: acp_agent.id, runtime: "claude")

      # gemini was the `false` case until #659. No runtime an *agent* may name
      # is legacy any more, but a conversation's runtime column carries no
      # inclusion validation, so a row written before a runtime was retired —
      # or by a future one with no adapter — still has to report false rather
      # than crash.
      legacy_conv =
        insert_conversation(user_id: user.id, agent_id: acp_agent.id, runtime: "retired-runtime")

      for {conv, expected} <- [{acp_conv, true}, {legacy_conv, false}] do
        conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

        assert json_response(conn, 200)["data"]["acp"] == expected
      end
    end

    test "returns 404 when the conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      conn = get(conn, "/api/conversations/#{conv.id}")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:conversation_id/turns" do
    test "returns 200 with turns list for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, [])

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert turn.id in ids
    end

    test "carries each turn's usage and the conversation's usage_total (#827)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv, status: "completed")
      insert_turn(conv, status: "completed")

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(t1, %{
          "input" => 120,
          "output" => 30,
          "cache_read" => 100
        })

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/turns")
        |> json_response(200)

      assert [
               %{"usage" => %{"input" => 120, "output" => 30, "cache_read" => 100}},
               %{"usage" => nil}
             ] = body["data"]

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}")
        |> json_response(200)

      assert body["data"]["usage_total"] == %{"input" => 120, "output" => 30}
    end

    test "returns 200 with an empty list when there are no turns", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns 404 when the conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}/turns")

      assert json_response(conn, 404)
    end
  end

  describe "subscription gate" do
    test "POST /api/conversations/:id/prompts returns 402 when cancelled", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      # Prompting wakes a dormant conversation, which provisions a fresh sprite.
      # It was the one provisioning path with no billing check at all.
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :subscription_required}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hi"})

      body = json_response(conn, 402)
      assert body["error"] == "subscription_required"
      assert body["upgrade_url"] == "/account/billing"
    end

    test "POST /api/conversations returns 402 when cancelled", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      {:ok, _} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "canceled"})
        |> Fountain.Repo.update()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 402)["error"] == "subscription_required"
    end
  end

  describe "sandbox concurrency cap" do
    test "POST /api/conversations returns 429 at the cap", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      for _ <- 1..Fountain.Quotas.default_limit(),
          do: insert_sandbox(user_id: user.id, status: "ready")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      body = json_response(conn, 429)
      assert body["error"] == "sandbox_quota_exceeded"
      assert body["active_sandboxes"] == 5
      assert body["limit"] == 5
    end

    test "POST /api/conversations succeeds below the cap", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      insert_sandbox(user_id: user.id, status: "ready")

      stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 201)
    end

    test "prompting a dormant conversation is capped too", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      # send_prompt on a dead GenServer wakes the conversation, which provisions
      # a fresh sprite — so it has to be subject to the same cap, or the cap is
      # trivially bypassed by prompting instead of creating.
      conv = insert_conversation(user_id: user.id)
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, {:sandbox_quota_exceeded, %{count: 5, limit: 5}}}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hi"})

      assert json_response(conn, 429)["error"] == "sandbox_quota_exceeded"
    end
  end

  describe "DELETE /api/conversations/:id" do
    test "deletes the conversation and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{conv.id}")

      assert conn.status == 204
    end

    test "returns 404 when the conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{other_conv.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      conn = delete(conn, "/api/conversations/#{conv.id}")
      assert json_response(conn, 401)
    end
  end

  describe "infer_provenance/1" do
    test "returns {\"api\", nil} when header is nil" do
      assert ConversationController.infer_provenance(nil) == {"api", nil}
    end

    test "returns {\"api\", nil} when header is an empty string" do
      assert ConversationController.infer_provenance("") == {"api", nil}
    end

    test "returns {\"agent\", id} when header contains a conversation id" do
      assert ConversationController.infer_provenance("some-conv-uuid") ==
               {"agent", "some-conv-uuid"}
    end
  end

  describe "POST /api/conversations" do
    test "returns 402 when user has a canceled subscription", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      Fountain.Repo.update!(Ecto.Changeset.change(user, subscription_status: "canceled"))
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/conversations", Jason.encode!(%{"agent_id" => agent.id}))

      assert json_response(conn, 402)
    end

    test "returns 404 when agent_id does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_agent_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/conversations",
          Jason.encode!(%{"agent_id" => unknown_agent_id, "prompt" => "hello"})
        )

      assert json_response(conn, 404)
    end

    test "returns 404 when agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/conversations",
          Jason.encode!(%{"agent_id" => other_agent.id, "prompt" => "hello"})
        )

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/prompts" do
    test "returns 200 with status queued on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 200)["status"] == "queued"
    end

    test "returns 404 when ConversationServer is not running", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :not_running}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end

    test "returns 400 when conversation is busy", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :busy}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 400)
    end

    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{unknown_id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end

    # The #332 trio: each of these used to blow the hand-maintained case
    # clause and 500. All three run the real wake path, no stubs.

    test "returns 410 when the conversation is terminated", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "terminated")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 410)["error"] == "conversation_terminated"
    end

    test "returns 422 when the conversation's agent was deleted", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "idle")
      assert conv.agent_id == nil

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 422)["error"] == "no_agent"
    end

    test "returns 422 when the wake path surfaces a changeset error", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, Fountain.Conversations.Sandbox.changeset(%Fountain.Conversations.Sandbox{}, %{})}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "an unknown refusal atom is a 422, not a CaseClauseError 500", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :some_future_refusal}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 422)["error"] == "some_future_refusal"
    end

    test "returns 404 when conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{other_conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/terminate" do
    test "returns 204 on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :terminate_conversation, fn _id, _opts -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/terminate")

      assert conn.status == 204
    end

    test "returns 404 when ConversationServer is not running", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :terminate_conversation, fn _id, _opts ->
        {:error, :not_running}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/terminate")

      assert json_response(conn, 404)
    end

    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{unknown_id}/terminate")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/interrupt" do
    test "returns 204 on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :interrupt, fn _id, _opts -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert conn.status == 204
    end

    test "returns 404 when ConversationServer is not running", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :interrupt, fn _id, _opts -> {:error, :not_running} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert json_response(conn, 404)
    end

    test "returns 409 conflict when conversation is idle", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :interrupt, fn _id, _opts -> {:error, :idle} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert json_response(conn, 409)
    end

    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{unknown_id}/interrupt")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/conversations/:conversation_id/stream" do
    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{unknown_id}/stream")

      assert json_response(conn, 404)
    end

    test "returns 200 with text/event-stream content-type when wait=false", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    # parse_bool_param("true") returns true, but wait=true blocks in sse_loop
    # (60 s timeout), so we pass wait=false here and verify the endpoint
    # still returns 200 — the "true" branch is covered by the unit path
    # exercised whenever the default (true) is used in production.
    # Instead we verify that explicitly passing wait=false (parse_bool_param
    # "false" → false) closes the stream immediately with 200.
    test "returns 200 when wait=false is explicit (parse_bool_param \"false\" branch)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when streams param is provided (parse_streams_param branch)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=stdout")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when Last-Event-ID is non-integer (parse_last_event_id :error branch defaults to 0)",
         %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "abc")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when wait=0 (parse_bool_param \"0\" → false, non-blocking)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=0")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when streams= is empty string (parse_streams_param \"\" → nil)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when Last-Event-ID is empty string (parse_last_event_id \"\" → 0)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end
  end

  # Every test above passed while the endpoint 406'd for every real client,
  # because Phoenix.ConnTest sends no Accept header and `plug :accepts` then
  # falls through to the default format. A real SSE client — the Go CLI, the
  # browser's EventSource, curl -H — sends `Accept: text/event-stream`, which
  # `plug :accepts, ["json"]` refuses before the action runs. So these tests
  # send the header on purpose.
  describe "GET /api/conversations/:conversation_id/stream — content negotiation" do
    test "accepts the Accept header a real SSE client sends", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "still replays buffered events with that header set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "hello"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert conn.resp_body =~ "event: output"
      assert conn.resp_body =~ "hello"
    end

    test "an unknown conversation still renders a JSON 404", %{conn: conn, raw_key: raw_key} do
      # The route negotiates no format at all now, so the fallback path has to
      # keep working without one.
      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{Ecto.UUID.generate()}/stream")

      assert json_response(conn, 404)
    end

    test "authentication is still enforced on the stream route", %{conn: conn, user: user} do
      # The stream lives in its own scope now. It shares the `:api` pipeline
      # rather than a copy of it, and this is what holds that true.
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert json_response(conn, 401)
    end

    test "another tenant's conversation is still a 404", %{conn: conn, raw_key: raw_key} do
      other = insert_conversation(user_id: insert_verified_user().id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{other.id}/stream?wait=false")

      assert json_response(conn, 404)
    end

    test "JSON endpoints still refuse text/event-stream", %{conn: conn, raw_key: raw_key} do
      # The fix is scoped to the stream route: negotiation was not loosened
      # across /api, so asking a JSON endpoint for an event stream is still a
      # 406 rather than a 500 from a missing template.
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations")
      end
    end
  end

  describe "GET /api/conversations/:conversation_id/stream with log events (replay path)" do
    test "replays existing log events when wait=false and conversation has events", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "hello"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      body = conn.resp_body
      assert body =~ "event: output"
      assert body =~ "hello"
    end

    test "replays only matching stream events when streams filter is set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "stdout-data"})
      insert_log_event(conv, %{kind: "output", stream: "stderr", data: "stderr-data"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=stdout")

      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "stdout-data"
      refute body =~ "stderr-data"
    end

    test "replays events after last_event_id when Last-Event-ID header is set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      ev1 = insert_log_event(conv, %{kind: "output", stream: "stdout", data: "first"})
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "second"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "#{ev1.id}")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      body = conn.resp_body
      refute body =~ "first"
      assert body =~ "second"
    end
  end

  describe "POST /api/conversations — parent conversation header" do
    test "returns 201 when x-fountain-parent-conversation-id header is set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      parent_conv = insert_conversation(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("x-fountain-parent-conversation-id", parent_conv.id)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 201)
    end
  end

  describe "POST /api/conversations with environment_id (#783)" do
    setup %{user: user} do
      stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
      agent_env = insert_env(user_id: user.id)
      other_env = insert_env(user_id: user.id)
      agent = insert_agent(user_id: user.id, environment_id: agent_env.id)
      %{agent: agent, other_env: other_env}
    end

    test "provisions from the named environment and reports it", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent,
      other_env: other_env
    } do
      body = %{"agent_id" => agent.id, "environment_id" => other_env.id}

      data =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", body)
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["environment_id"] == other_env.id
    end

    test "a foreign environment is a 404 — indistinguishable from an unknown one", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      foreign = insert_env(user_id: insert_verified_user().id)

      for id <- [foreign.id, Ecto.UUID.generate()] do
        assert conn
               |> authed_with_key(raw_key)
               |> post_json("/api/conversations", %{
                 "agent_id" => agent.id,
                 "environment_id" => id
               })
               |> json_response(404)
               |> Map.fetch!("error") == "environment_not_found"
      end
    end

    test "an environment outside the agent's allowlist is a 422 environment_not_allowed", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent,
      other_env: other_env
    } do
      {:ok, agent} = Fountain.Agents.update_agent(agent, %{allowed_environment_ids: []})

      resp =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "environment_id" => other_env.id
        })
        |> json_response(422)

      assert resp["error"] == "environment_not_allowed"
    end
  end

  describe "POST /api/conversations with channel_id (#774)" do
    # A client that forgets its sessions — a restarted buzz-acp — must land back
    # on the same conversation, and so the same sandbox, rather than opening a
    # fresh one per restart. The key is opaque; Fountain only matches it.
    setup %{user: user} do
      stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
      %{agent: insert_agent(user_id: user.id)}
    end

    defp create(conn, raw_key, body) do
      conn |> authed_with_key(raw_key) |> post_json("/api/conversations", body)
    end

    test "first call creates (201), second resumes the same conversation (200, meta.resumed)",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-abc"}

      first = create(conn, raw_key, body) |> json_response(201)
      assert first["data"]["channel_id"] == "chan-abc"
      assert first["meta"]["resumed"] == false

      second = create(conn, raw_key, body) |> json_response(200)
      assert second["data"]["id"] == first["data"]["id"]
      assert second["meta"]["resumed"] == true

      # Only one conversation exists for it.
      assert [_] = Fountain.Conversations.list_conversations(agent.user_id)
    end

    test "different channels, and different vaults on one channel, are different conversations",
         %{conn: conn, raw_key: raw_key, agent: agent, user: user} do
      vault = insert_vault(user_id: user.id)

      a =
        create(conn, raw_key, %{"agent_id" => agent.id, "channel_id" => "chan-a"})
        |> json_response(201)

      b =
        create(conn, raw_key, %{"agent_id" => agent.id, "channel_id" => "chan-b"})
        |> json_response(201)

      a_vault =
        create(conn, raw_key, %{
          "agent_id" => agent.id,
          "channel_id" => "chan-a",
          "vault_id" => vault.id
        })
        |> json_response(201)

      ids = [a, b, a_vault] |> Enum.map(& &1["data"]["id"])
      assert length(Enum.uniq(ids)) == 3

      # And each binding resumes its own.
      assert create(conn, raw_key, %{"agent_id" => agent.id, "channel_id" => "chan-a"})
             |> json_response(200)
             |> get_in(["data", "id"]) == a["data"]["id"]
    end

    test "a terminated conversation is not resumed — a new one takes over the binding",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-t"}
      first = create(conn, raw_key, body) |> json_response(201)

      conv = Fountain.Conversations._unsafe_get_conversation!(first["data"]["id"])
      {:ok, _} = Fountain.Conversations.update_conversation(conv, %{status: "terminated"})

      second = create(conn, raw_key, body) |> json_response(201)
      refute second["data"]["id"] == first["data"]["id"]

      # From now on the new one is what resumes.
      assert create(conn, raw_key, body) |> json_response(200) |> get_in(["data", "id"]) ==
               second["data"]["id"]
    end

    test "fresh: true opens a new conversation despite the binding, and it takes over",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-r"}
      first = create(conn, raw_key, body) |> json_response(201)

      assert create(conn, raw_key, body) |> json_response(200) |> get_in(["data", "id"]) ==
               first["data"]["id"]

      # The harness's owner rotated the channel (ACP _meta.freshSession).
      rotated = create(conn, raw_key, Map.put(body, "fresh", true)) |> json_response(201)
      refute rotated["data"]["id"] == first["data"]["id"]
      assert rotated["data"]["channel_id"] == "chan-r"
      assert rotated["meta"]["resumed"] == false

      # From now on the new one is what an ordinary session/new resumes, and
      # the old one is unbound (not terminated — it may be mid-turn).
      assert create(conn, raw_key, body) |> json_response(200) |> get_in(["data", "id"]) ==
               rotated["data"]["id"]

      old = Fountain.Conversations._unsafe_get_conversation!(first["data"]["id"])
      assert old.channel_id == nil
      refute old.status in ["terminated", "failed"]

      # fresh: false / absent / a non-boolean does not rotate.
      assert create(conn, raw_key, Map.put(body, "fresh", false))
             |> json_response(200)
             |> get_in(["data", "id"]) == rotated["data"]["id"]

      # Without a channel key fresh is meaningless — creates like any other.
      assert %{"data" => %{"channel_id" => nil}} =
               create(conn, raw_key, %{"agent_id" => agent.id, "fresh" => true})
               |> json_response(201)
    end

    test "another user's binding is invisible", %{conn: conn, agent: agent} do
      other = insert_verified_user()
      {_k, other_key} = insert_api_key(other)
      other_agent = insert_agent(user_id: other.id)

      mine = create(conn, other_key, %{"agent_id" => other_agent.id, "channel_id" => "shared"})
      assert json_response(mine, 201)

      # Same channel key, different tenant and agent: a fresh conversation.
      {_k, my_key} = insert_api_key(Fountain.Repo.get!(Fountain.Accounts.User, agent.user_id))

      assert create(conn, my_key, %{"agent_id" => agent.id, "channel_id" => "shared"})
             |> json_response(201)
    end

    test "without channel_id nothing changes: every call creates", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      a = create(conn, raw_key, %{"agent_id" => agent.id}) |> json_response(201)
      b = create(conn, raw_key, %{"agent_id" => agent.id}) |> json_response(201)
      refute a["data"]["id"] == b["data"]["id"]
      assert a["data"]["channel_id"] == nil
    end
  end

  describe "POST /api/conversations with images" do
    test "returns 201 with conversation when images array is provided (decode_images non-empty branch)",
         %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      image_data = Base.encode64("fake-image-bytes")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "images" => [%{"media_type" => "image/png", "data" => image_data}]
        })

      assert json_response(conn, 201)
    end

    test "returns 201 with conversation when no images provided (decode_images [] branch)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "images" => []
        })

      assert json_response(conn, 201)
    end
  end
end
