defmodule FountainWeb.OpenAIControllerTest do
  @moduledoc """
  The OpenAI-compatible endpoint: what a chat client or gateway sends, what it
  gets back, and what it must never get back.

  As in the AG-UI suite, the turn is played through replay — its log events
  are written while the request is inside `send_prompt`, so a request
  completes synchronously and the assertions are about the wire shape rather
  than timing. The quiet timeout is dropped to a fraction of a second so a
  test that never ends a turn fails fast.
  """
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias FountainWeb.OpenAIController

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, name: "pr-reviewer")

    previous = Application.get_env(:fountain, :openai_quiet_timeout_ms)
    Application.put_env(:fountain, :openai_quiet_timeout_ms, 250)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :openai_quiet_timeout_ms, previous),
        else: Application.delete_env(:fountain, :openai_quiet_timeout_ms)
    end)

    # Alpha, behind a flag: on for the whole module, off again in one test.
    previous_flags = Application.get_env(:fountain, :feature_flag_overrides)
    Application.put_env(:fountain, :feature_flag_overrides, %{"openai_compat" => true})

    on_exit(fn ->
      if previous_flags,
        do: Application.put_env(:fountain, :feature_flag_overrides, previous_flags),
        else: Application.delete_env(:fountain, :feature_flag_overrides)
    end)

    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    stub(ConversationServer, :whereis, fn _id -> nil end)

    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  ## ─── Helpers ──────────────────────────────────────────────────────────────

  defp bound_conversation(user, agent, thread) do
    insert_conversation(
      user_id: user.id,
      agent: agent,
      channel_id: OpenAIController.channel_id(thread),
      status: "idle"
    )
  end

  defp chat(conn, raw_key, body, headers \\ []) do
    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    post(conn, "/v1/chat/completions", Jason.encode!(body))
  end

  defp request(model, text, extra \\ %{}) do
    Map.merge(
      %{"model" => model, "messages" => [%{"role" => "user", "content" => text}]},
      extra
    )
  end

  # One SSE message per `data:` line, `[DONE]` kept as the atom.
  defp events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn message ->
      case String.trim_leading(message) do
        "data: [DONE]" -> [:done]
        "data: " <> json -> [Jason.decode!(json)]
        _ -> []
      end
    end)
  end

  defp deltas(conn, field) do
    conn
    |> events()
    |> Enum.reject(&(&1 == :done))
    |> Enum.flat_map(&(&1["choices"] || []))
    |> Enum.map_join("", &(get_in(&1, ["delta", field]) || ""))
  end

  defp acp(update) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "sess-1", "update" => update}
    })
  end

  defp chunk(text),
    do: %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    }

  defp thought(text),
    do: %{
      "sessionUpdate" => "agent_thought_chunk",
      "content" => %{"type" => "text", "text" => text}
    }

  defp tool_call(id, title),
    do: %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => id,
      "title" => title,
      "kind" => "execute"
    }

  defp tool_done(id, status),
    do: %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => status}

  defp agent_that_cannot_provision(user) do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)

    insert_agent(user_id: user.id, name: "offline", sandbox_provider: "runner")
  end

  defp play_turn(conv, updates, ending \\ {"done", %{}}) do
    turn = insert_turn(conv, status: "running")

    Conversations.publish_stage(conv.id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn.turn_number
    })

    for update <- updates do
      event =
        insert_log_event(conv,
          kind: "output",
          stream: "acp",
          turn_id: turn.id,
          data: acp(update)
        )

      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, event})
    end

    {state, meta} = ending
    Conversations.publish_stage(conv.id, "turn", state, Map.put(meta, :turn_id, turn.id))
    turn
  end

  ## ─── stream: false ────────────────────────────────────────────────────────

  describe "POST /v1/chat/completions" do
    test "answers one chat.completion with the assembled text", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn conv_id, prompt, [], _opts ->
        assert conv_id == conv.id
        assert prompt == "what is 2 + 2?"
        play_turn(conv, [chunk("4"), chunk(", obviously")])
        :ok
      end)

      conn =
        chat(conn, raw_key, request("pr-reviewer", "what is 2 + 2?"), [
          {"x-fountain-thread", "t1"}
        ])

      body = json_response(conn, 200)
      assert body["object"] == "chat.completion"
      assert body["model"] == "pr-reviewer"
      assert "chatcmpl-" <> _ = body["id"]

      assert [%{"index" => 0, "finish_reason" => "stop", "message" => message}] = body["choices"]
      assert message == %{"role" => "assistant", "content" => "4, obviously"}

      assert body["usage"] == %{
               "prompt_tokens" => 0,
               "completion_tokens" => 0,
               "total_tokens" => 0
             }

      assert body["fountain"]["conversation_id"] == conv.id
      assert body["fountain"]["thread"] == "t1"
    end

    test "the model may be the agent's id as well as its name", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("by id")])
        :ok
      end)

      conn = chat(conn, raw_key, request(agent.id, "hi"), [{"x-fountain-thread", "t1"}])

      assert json_response(conn, 200)["model"] == "pr-reviewer"
    end

    test "prompts with the newest user message only, and the system prompt is not replayed", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, prompt, [], _opts ->
        assert prompt == "and the one after that?"
        play_turn(conv, [chunk("ok")])
        :ok
      end)

      messages = [
        %{"role" => "system", "content" => "You are Ada."},
        %{"role" => "user", "content" => "the first question"},
        %{"role" => "assistant", "content" => "the first answer"},
        %{"role" => "user", "content" => "and the one after that?"}
      ]

      conn =
        chat(conn, raw_key, %{"model" => "pr-reviewer", "messages" => messages}, [
          {"x-fountain-thread", "t1"}
        ])

      assert json_response(conn, 200)
    end

    test "reads multi-part text content", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, prompt, [], _opts ->
        assert prompt == "look at this"
        play_turn(conv, [chunk("ok")])
        :ok
      end)

      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "look at this"}]}
      ]

      conn =
        chat(conn, raw_key, %{"model" => "pr-reviewer", "messages" => messages}, [
          {"x-fountain-thread", "t1"}
        ])

      assert json_response(conn, 200)
    end

    test "a data: image_url part becomes a prompt image", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")
      png = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

      expect(ConversationServer, :send_prompt, fn _id, prompt, images, _opts ->
        assert prompt == "what is this?"
        assert [%{media_type: "image/png", data: <<137, 80, _::binary>>}] = images
        play_turn(conv, [chunk("a png")])
        :ok
      end)

      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "what is this?"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> png}}
          ]
        }
      ]

      conn =
        chat(conn, raw_key, %{"model" => "pr-reviewer", "messages" => messages}, [
          {"x-fountain-thread", "t1"}
        ])

      assert json_response(conn, 200)
    end

    test "a remote image_url is refused, not fetched", %{conn: conn, raw_key: raw_key} do
      reject(&ConversationServer.send_prompt/4)

      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/x.png"}}
          ]
        }
      ]

      conn =
        chat(conn, raw_key, %{"model" => "pr-reviewer", "messages" => messages}, [
          {"x-fountain-thread", "t1"}
        ])

      assert json_response(conn, 400)["error"]["message"] =~ "data: URL"
    end

    test "a failed turn is a 500 in the error envelope", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("partial")], {"failed", %{reason: "Authentication required"}})
        :ok
      end)

      conn = chat(conn, raw_key, request("pr-reviewer", "hi"), [{"x-fountain-thread", "t1"}])

      assert %{"error" => %{"message" => "Authentication required", "code" => "turn_failed"}} =
               json_response(conn, 500)
    end
  end

  ## ─── The thread key ───────────────────────────────────────────────────────

  describe "the thread key" do
    test "binds the header to one conversation, so a second request resumes it", %{
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, 2, fn conv_id, _prompt, [], _opts ->
        assert conv_id == conv.id
        play_turn(conv, [chunk("same sandbox")])
        :ok
      end)

      for _ <- 1..2 do
        conn =
          chat(build_conn(), raw_key, request("pr-reviewer", "again"), [
            {"x-fountain-thread", "t1"}
          ])

        assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) ==
                 "same sandbox"
      end
    end

    test "falls back to the user field", %{user: user, agent: agent, raw_key: raw_key} do
      conv = bound_conversation(user, agent, "alice")

      expect(ConversationServer, :send_prompt, fn conv_id, _prompt, [], _opts ->
        assert conv_id == conv.id
        play_turn(conv, [chunk("hi alice")])
        :ok
      end)

      conn = chat(build_conn(), raw_key, request("pr-reviewer", "hello", %{"user" => "alice"}))

      assert json_response(conn, 200)["fountain"]["thread"] == "alice"
    end

    test "the header wins over the user field", %{user: user, agent: agent, raw_key: raw_key} do
      conv = bound_conversation(user, agent, "t1")
      _other = bound_conversation(user, agent, "alice")

      expect(ConversationServer, :send_prompt, fn conv_id, _prompt, [], _opts ->
        assert conv_id == conv.id
        play_turn(conv, [chunk("t1")])
        :ok
      end)

      conn =
        chat(build_conn(), raw_key, request("pr-reviewer", "hello", %{"user" => "alice"}), [
          {"x-fountain-thread", "t1"}
        ])

      assert json_response(conn, 200)["fountain"]["thread"] == "t1"
    end

    test "neither is a 400 that names the header", %{conn: conn, raw_key: raw_key} do
      reject(&ConversationServer.send_prompt/4)

      conn = chat(conn, raw_key, request("pr-reviewer", "hello"))

      assert %{"error" => %{"type" => "invalid_request_error", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "X-Fountain-Thread"
    end

    test "a different key opens its own conversation rather than resuming another's", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = agent_that_cannot_provision(user)
      _bound = bound_conversation(user, agent, "t1")

      reject(&ConversationServer.send_prompt/4)

      conn = chat(conn, raw_key, request("offline", "hello"), [{"x-fountain-thread", "t2"}])

      assert json_response(conn, 409)["error"] == "no_runner_online"
    end

    test "a busy thread is 409 with Retry-After, not a queue", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      _conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts -> {:error, :busy} end)

      conn = chat(conn, raw_key, request("pr-reviewer", "hello"), [{"x-fountain-thread", "t1"}])

      assert json_response(conn, 409)["error"]["code"] == "thread_busy"
      assert get_resp_header(conn, "retry-after") == ["5"]
    end
  end

  ## ─── stream: true ─────────────────────────────────────────────────────────

  describe "stream: true" do
    test "streams chat.completion.chunk deltas and ends with [DONE]", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("4"), chunk(", obviously")])
        :ok
      end)

      conn =
        chat(conn, raw_key, request("pr-reviewer", "2 + 2?", %{"stream" => true}), [
          {"x-fountain-thread", "t1"}
        ])

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")

      events = events(conn)
      assert List.last(events) == :done

      chunks = Enum.reject(events, &(&1 == :done))
      assert Enum.all?(chunks, &(&1["object"] == "chat.completion.chunk"))
      assert chunks |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 1

      [first | _] = chunks
      assert get_in(first, ["choices", Access.at(0), "delta", "role"]) == "assistant"

      assert deltas(conn, "content") == "4, obviously"

      last = List.last(chunks)
      assert get_in(last, ["choices", Access.at(0), "finish_reason"]) == "stop"
      assert get_in(last, ["choices", Access.at(0), "delta"]) == %{}
    end

    test "thinking and tool use stream as reasoning_content, never as tool calls", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [
          thought("let me look"),
          tool_call("c1", "Bash"),
          tool_done("c1", "completed"),
          chunk("done")
        ])

        :ok
      end)

      conn =
        chat(conn, raw_key, request("pr-reviewer", "look", %{"stream" => true}), [
          {"x-fountain-thread", "t1"}
        ])

      reasoning = deltas(conn, "reasoning_content")
      assert reasoning =~ "let me look"
      assert reasoning =~ "→ Bash"
      assert reasoning =~ "← ok"
      assert deltas(conn, "content") == "done"
      refute conn.resp_body =~ "tool_calls"
    end

    test "a failed turn sends an error event, then [DONE]", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("partial")], {"failed", %{reason: "boom"}})
        :ok
      end)

      conn =
        chat(conn, raw_key, request("pr-reviewer", "hi", %{"stream" => true}), [
          {"x-fountain-thread", "t1"}
        ])

      events = events(conn)

      assert [%{"error" => %{"message" => "boom", "code" => "turn_failed"}}, :done] =
               Enum.take(events, -2)
    end

    test "a turn that never ends fails on the quiet timeout", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        turn = insert_turn(conv, status: "running")
        Conversations.publish_stage(conv.id, "turn", "started", %{turn_id: turn.id})
        :ok
      end)

      conn =
        chat(conn, raw_key, request("pr-reviewer", "hi", %{"stream" => true}), [
          {"x-fountain-thread", "t1"}
        ])

      assert [%{"error" => %{"message" => message}}, :done] = Enum.take(events(conn), -2)
      assert message =~ "quiet"
    end
  end

  ## ─── Refusals ─────────────────────────────────────────────────────────────

  describe "refusals" do
    test "the flag off is a 404 on every route, in the envelope", %{
      conn: conn,
      raw_key: raw_key
    } do
      Application.put_env(:fountain, :feature_flag_overrides, %{})
      reject(&ConversationServer.send_prompt/4)

      chat = chat(conn, raw_key, request("pr-reviewer", "hi"), [{"x-fountain-thread", "t1"}])
      assert json_response(chat, 404)["error"]["code"] == "openai_compat_not_enabled"

      models = build_conn() |> authed_with_key(raw_key) |> get("/v1/models")
      assert json_response(models, 404)["error"]["code"] == "openai_compat_not_enabled"
    end

    test "an unknown model is a 404 in OpenAI's envelope", %{conn: conn, raw_key: raw_key} do
      conn = chat(conn, raw_key, request("gpt-4o", "hi"), [{"x-fountain-thread", "t1"}])

      assert %{"error" => %{"code" => "model_not_found", "type" => "invalid_request_error"}} =
               json_response(conn, 404)
    end

    test "another tenant's agent is an unknown model", %{conn: conn, raw_key: raw_key} do
      other = insert_verified_user()
      theirs = insert_agent(user_id: other.id, name: "theirs")

      conn = chat(conn, raw_key, request(theirs.id, "hi"), [{"x-fountain-thread", "t1"}])

      assert json_response(conn, 404)["error"]["code"] == "model_not_found"
    end

    test "no user message is a 400", %{conn: conn, raw_key: raw_key} do
      body = %{"model" => "pr-reviewer", "messages" => [%{"role" => "system", "content" => "x"}]}
      conn = chat(conn, raw_key, body, [{"x-fountain-thread", "t1"}])

      assert json_response(conn, 400)["error"]["message"] =~ "user message"
    end

    test "no bearer token is a 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", Jason.encode!(request("pr-reviewer", "hi")))

      assert conn.status == 401
    end
  end

  ## ─── Models ───────────────────────────────────────────────────────────────

  describe "GET /v1/models" do
    test "lists the tenant's agents as models, by name", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      other = insert_verified_user()
      _theirs = insert_agent(user_id: other.id, name: "theirs")
      _second = insert_agent(user_id: user.id, name: "second")

      conn = conn |> authed_with_key(raw_key) |> get("/v1/models")

      body = json_response(conn, 200)
      assert body["object"] == "list"
      assert body["data"] |> Enum.map(& &1["id"]) |> Enum.sort() == ["pr-reviewer", "second"]

      model = Enum.find(body["data"], &(&1["id"] == "pr-reviewer"))
      assert model["object"] == "model"
      assert model["owned_by"] == "fountain"
      assert model["fountain"]["agent_id"] == agent.id
      assert is_integer(model["created"])
    end

    test "shows one model by name or id, 404 otherwise", %{
      conn: conn,
      agent: agent,
      raw_key: raw_key
    } do
      by_name = conn |> authed_with_key(raw_key) |> get("/v1/models/pr-reviewer")
      assert json_response(by_name, 200)["id"] == "pr-reviewer"

      by_id = build_conn() |> authed_with_key(raw_key) |> get("/v1/models/#{agent.id}")
      assert json_response(by_id, 200)["id"] == "pr-reviewer"

      missing = build_conn() |> authed_with_key(raw_key) |> get("/v1/models/gpt-4o")
      assert json_response(missing, 404)["error"]["code"] == "model_not_found"
    end
  end
end
