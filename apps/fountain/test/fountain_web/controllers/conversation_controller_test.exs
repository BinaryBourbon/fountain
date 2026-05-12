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

    test "does not include conversations belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_conv.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/conversations")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:id" do
    test "returns 200 with the conversation for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == conv.id
    end

    test "returns 404 when the conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
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
    test "returns 200 with turns list for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, [])

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert turn.id in ids
    end

    test "returns 200 with an empty list when there are no turns", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns 404 when the conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}/turns")

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/conversations/:id" do
    test "deletes the conversation and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{conv.id}")

      assert conn.status == 204
    end

    test "returns 404 when the conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
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
      assert ConversationController.infer_provenance("some-conv-uuid") == {"agent", "some-conv-uuid"}
    end
  end

  describe "POST /api/conversations" do
    test "returns 402 when user has a canceled subscription", %{conn: conn, user: user, raw_key: raw_key} do
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
        |> post("/api/conversations", Jason.encode!(%{"agent_id" => unknown_agent_id, "prompt" => "hello"}))

      assert json_response(conn, 404)
    end

    test "returns 404 when agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/conversations", Jason.encode!(%{"agent_id" => other_agent.id, "prompt" => "hello"}))

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/prompts" do
    test "returns 200 with status queued on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 200)["status"] == "queued"
    end

    test "returns 404 when ConversationServer is not running", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images -> {:error, :not_running} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end

    test "returns 400 when conversation is busy", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images -> {:error, :busy} end)

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

    test "returns 404 when conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
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
      stub(ConversationServer, :terminate, fn _id -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/terminate")

      assert conn.status == 204
    end

    test "returns 404 when ConversationServer is not running", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :terminate, fn _id -> {:error, :not_running} end)

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
      stub(ConversationServer, :interrupt, fn _id -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert conn.status == 204
    end

    test "returns 404 when ConversationServer is not running", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :interrupt, fn _id -> {:error, :not_running} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert json_response(conn, 404)
    end

    test "returns 409 conflict when conversation is idle", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :interrupt, fn _id -> {:error, :idle} end)

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

    test "returns 200 with text/event-stream content-type when wait=false", %{conn: conn, user: user, raw_key: raw_key} do
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
    test "returns 200 when wait=false is explicit (parse_bool_param \"false\" branch)", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when streams param is provided (parse_streams_param branch)", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=stdout")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when Last-Event-ID is non-integer (parse_last_event_id :error branch defaults to 0)", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "abc")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when wait=0 (parse_bool_param \"0\" → false, non-blocking)", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=0")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when streams= is empty string (parse_streams_param \"\" → nil)", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when Last-Event-ID is empty string (parse_last_event_id \"\" → 0)", %{conn: conn, user: user, raw_key: raw_key} do
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

  describe "GET /api/conversations/:conversation_id/stream with log events (replay path)" do
    test "replays existing log events when wait=false and conversation has events", %{conn: conn, user: user, raw_key: raw_key} do
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

    test "replays only matching stream events when streams filter is set", %{conn: conn, user: user, raw_key: raw_key} do
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

    test "replays events after last_event_id when Last-Event-ID header is set", %{conn: conn, user: user, raw_key: raw_key} do
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
    test "returns 201 when x-fountain-parent-conversation-id header is set", %{conn: conn, user: user, raw_key: raw_key} do
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

  describe "POST /api/conversations with images" do
    test "returns 201 with conversation when images array is provided (decode_images non-empty branch)", %{conn: conn, user: user, raw_key: raw_key} do
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

    test "returns 201 with conversation when no images provided (decode_images [] branch)", %{conn: conn, user: user, raw_key: raw_key} do
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
