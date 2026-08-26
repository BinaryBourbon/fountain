defmodule FountainWeb.AguiControllerTest do
  @moduledoc """
  The AG-UI endpoint: what a host sends, what it gets back, and what it must
  never get back.

  The stream is driven entirely through replay — the turn's log events are
  written while the request is inside `send_prompt`, so the run completes
  synchronously and the assertions are about the emitted protocol rather than
  about timing. The quiet timeout is dropped to a fraction of a second so a
  test that never ends a turn fails in milliseconds instead of hanging out the
  real ten minutes.
  """
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias FountainWeb.AguiController

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)

    previous = Application.get_env(:fountain, :agui_quiet_timeout_ms)
    Application.put_env(:fountain, :agui_quiet_timeout_ms, 250)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :agui_quiet_timeout_ms, previous),
        else: Application.delete_env(:fountain, :agui_quiet_timeout_ms)
    end)

    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    # No live server: the stream's monitor is best-effort and every turn in
    # here is played by the stub below, not by a real ConversationServer.
    stub(ConversationServer, :whereis, fn _id -> nil end)

    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  ## ─── Helpers ──────────────────────────────────────────────────────────────

  defp bound_conversation(user, agent, thread_id) do
    insert_conversation(
      user_id: user.id,
      agent: agent,
      channel_id: AguiController.channel_id(thread_id),
      status: "idle"
    )
  end

  defp run(conn, raw_key, agent_id, body, query \\ "") do
    conn
    |> authed_with_key(raw_key)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> post("/api/agui/#{agent_id}#{query}", Jason.encode!(body))
  end

  defp input(thread_id, text, extra \\ []) do
    %{
      "threadId" => thread_id,
      "runId" => "run-1",
      "messages" => Keyword.get(extra, :messages, [%{"role" => "user", "content" => text}]),
      "tools" => [],
      "context" => [],
      "state" => %{},
      "forwardedProps" => %{}
    }
  end

  # One SSE message per AG-UI event, `data:` only — heartbeat comments and
  # blank separators drop out here, as they do in any client's parser.
  defp events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn message ->
      case String.trim_leading(message) do
        "data: " <> json -> [Jason.decode!(json)]
        _ -> []
      end
    end)
  end

  defp types(conn), do: conn |> events() |> Enum.map(& &1["type"])

  defp text(conn) do
    conn
    |> events()
    |> Enum.filter(&(&1["type"] == "TEXT_MESSAGE_CONTENT"))
    |> Enum.map_join("", & &1["delta"])
  end

  defp thinking(conn) do
    conn
    |> events()
    |> Enum.filter(&(&1["type"] == "THINKING_TEXT_MESSAGE_CONTENT"))
    |> Enum.map_join("", & &1["delta"])
  end

  # A stored ACP line, exactly as the adapter writes one.
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

  # An agent pinned to the runner provider with no runner connected refuses
  # before anything is allocated, which is the cheapest observable proof that a
  # run took the *create* path rather than resuming something. Enabledness is
  # global application env — off in test config — which is why this module is
  # `async: false`.
  defp agent_that_cannot_provision(user) do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)

    insert_agent(user_id: user.id, sandbox_provider: "runner")
  end

  # Write the turn the way production does: a `turn`/`started` stage, the
  # runtime's output rows, then a terminal stage.
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

  ## ─── The happy path ───────────────────────────────────────────────────────

  describe "POST /api/agui/:agent_id" do
    test "streams a turn's text as one assistant message", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn conv_id, _prompt, [], _opts ->
        assert conv_id == conv.id
        play_turn(conv, [chunk("4"), chunk(", obviously")])
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "what is 2 + 2?"))

      assert conn.status == 200

      assert types(conn) == [
               "RUN_STARTED",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "RUN_FINISHED"
             ]

      assert text(conn) == "4, obviously"

      [started | _] = events(conn)
      assert started["threadId"] == "t1"
      assert started["runId"] == "run-1"
    end

    test "answers as an event stream, not JSON", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("hi")])
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"))

      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
    end

    # The whole design in one assertion: the host replays its transcript, and
    # only the newest user message reaches the sandbox that already lived
    # through the rest of it.
    test "prompts with the newest user message only, not the replayed transcript", %{
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
        %{"role" => "system", "content" => "You are Ada, Staff Engineer."},
        %{"role" => "user", "content" => "the first question"},
        %{"role" => "assistant", "content" => "the first answer"},
        %{"role" => "user", "content" => "and the one after that?"}
      ]

      conn = run(conn, raw_key, agent.id, input("t1", nil, messages: messages))

      assert "RUN_FINISHED" in types(conn)
    end

    test "binds the thread to one conversation, so a second run resumes it", %{
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

      for _run <- 1..2 do
        conn = run(build_conn(), raw_key, agent.id, input("t1", "again"))
        assert text(conn) == "same sandbox"
      end
    end

    # A run on an unbound thread has to *open* a conversation, and opening one
    # provisions a sandbox. The agent here is pinned to the runner provider
    # with no runner connected, which refuses before anything is allocated
    # (see runners/placement_test.exs) — so the create path is observable
    # without a sandbox existing anywhere.
    test "a different thread opens its own conversation rather than resuming another's", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = agent_that_cannot_provision(user)
      _bound = bound_conversation(user, agent, "t1")

      reject(&ConversationServer.send_prompt/4)

      conn = run(conn, raw_key, agent.id, input("t2", "hello"))

      assert json_response(conn, 409)["error"] == "no_runner_online"
    end
  end

  ## ─── Everything that is not the reply ─────────────────────────────────────

  describe "activity" do
    test "relays thinking and tool use as AG-UI thinking events", %{
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

      conn = run(conn, raw_key, agent.id, input("t1", "look at the repo"))

      assert thinking(conn) =~ "let me look"
      assert thinking(conn) =~ "→ Bash"
      assert thinking(conn) =~ "← ok"
      assert text(conn) == "done"

      # The thinking region opens and closes exactly once, and is closed
      # before the assistant message starts.
      assert Enum.count(types(conn), &(&1 == "THINKING_START")) == 1
      assert Enum.count(types(conn), &(&1 == "THINKING_END")) == 1

      thinking_end = Enum.find_index(types(conn), &(&1 == "THINKING_END"))
      text_start = Enum.find_index(types(conn), &(&1 == "TEXT_MESSAGE_START"))
      assert thinking_end < text_start
    end

    test "a failed tool says so", %{conn: conn, user: user, agent: agent, raw_key: raw_key} do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [tool_call("c1", "Bash"), tool_done("c1", "failed"), chunk("hm")])
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "try it"))

      assert thinking(conn) =~ "← failed"
    end

    test "?activity=off streams the reply and nothing else", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [thought("noise"), tool_call("c1", "Bash"), chunk("signal")])
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"), "?activity=off")

      assert text(conn) == "signal"
      refute "THINKING_START" in types(conn)
      refute "THINKING_TEXT_MESSAGE_CONTENT" in types(conn)
    end

    # Interleaving is where a half-open message would leave a host spinning:
    # each channel has to be closed before the other opens.
    test "text and thinking never overlap", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("first"), thought("wait"), chunk("second")])
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"))

      assert types(conn) == [
               "RUN_STARTED",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "THINKING_START",
               "THINKING_TEXT_MESSAGE_START",
               "THINKING_TEXT_MESSAGE_CONTENT",
               "THINKING_TEXT_MESSAGE_END",
               "THINKING_END",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "RUN_FINISHED"
             ]

      # Two messages, two ids: a host that reopened the first would concatenate
      # the reply into the wrong bubble.
      ids =
        conn
        |> events()
        |> Enum.filter(&(&1["type"] == "TEXT_MESSAGE_START"))
        |> Enum.map(& &1["messageId"])

      assert length(Enum.uniq(ids)) == 2
    end
  end

  ## ─── Failure ──────────────────────────────────────────────────────────────

  describe "failure" do
    test "a failed turn ends the run with RUN_ERROR, not RUN_FINISHED", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("half an ans")], {"failed", %{reason: "sprite connection lost"}})
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"))

      types = types(conn)
      assert "RUN_ERROR" in types
      refute "RUN_FINISHED" in types

      # The half-written message is closed first. A host holding an open
      # message renders a reply that never stops arriving.
      assert Enum.find_index(types, &(&1 == "TEXT_MESSAGE_END")) <
               Enum.find_index(types, &(&1 == "RUN_ERROR"))

      error = conn |> events() |> List.last()
      assert error["message"] =~ "sprite connection lost"
    end

    test "an interrupted turn still finishes the run", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        play_turn(conv, [chunk("as far as I got")], {"interrupted", %{}})
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"))

      assert "RUN_FINISHED" in types(conn)
      assert thinking(conn) =~ "interrupted"
    end

    test "another turn's output is not attributed to this run", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        stranger = insert_turn(conv, status: "running")

        insert_log_event(conv,
          kind: "output",
          stream: "acp",
          turn_id: stranger.id,
          data: acp(chunk("someone else's answer"))
        )

        play_turn(conv, [chunk("mine")])
        :ok
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"))

      assert text(conn) == "mine"
      refute text(conn) =~ "someone else"
    end

    test "a busy conversation is refused before the stream opens", %{
      conn: conn,
      user: user,
      agent: agent,
      raw_key: raw_key
    } do
      _conv = bound_conversation(user, agent, "t1")

      expect(ConversationServer, :send_prompt, fn _id, _prompt, [], _opts ->
        {:error, :busy}
      end)

      conn = run(conn, raw_key, agent.id, input("t1", "hello"))

      assert json_response(conn, 400)["error"] == "conversation_busy"
    end
  end

  ## ─── The envelope ─────────────────────────────────────────────────────────

  describe "run input" do
    test "400 without a threadId", %{conn: conn, agent: agent, raw_key: raw_key} do
      body = %{"runId" => "run-1", "messages" => [%{"role" => "user", "content" => "hi"}]}

      conn = run(conn, raw_key, agent.id, body)

      assert json_response(conn, 400)["error"] =~ "threadId"
    end

    test "400 without a runId", %{conn: conn, agent: agent, raw_key: raw_key} do
      body = %{"threadId" => "t1", "messages" => [%{"role" => "user", "content" => "hi"}]}

      conn = run(conn, raw_key, agent.id, body)

      assert json_response(conn, 400)["error"] =~ "runId"
    end

    test "400 when no message in the run came from a user", %{
      conn: conn,
      agent: agent,
      raw_key: raw_key
    } do
      body = %{
        "threadId" => "t1",
        "runId" => "run-1",
        "messages" => [%{"role" => "assistant", "content" => "hello?"}]
      }

      conn = run(conn, raw_key, agent.id, body)

      assert json_response(conn, 400)["error"] =~ "user message"
    end

    test "multi-part content is read rather than ignored", %{
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
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "look at "},
            %{"type" => "text", "text" => "this"}
          ]
        }
      ]

      conn = run(conn, raw_key, agent.id, input("t1", nil, messages: messages))

      assert "RUN_FINISHED" in types(conn)
    end
  end

  ## ─── Who may run what ─────────────────────────────────────────────────────

  describe "auth" do
    test "401 without a key", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/agui/#{agent.id}", Jason.encode!(input("t1", "hello")))

      assert conn.status == 401
    end

    test "404 for an agent that does not exist", %{conn: conn, raw_key: raw_key} do
      conn = run(conn, raw_key, Ecto.UUID.generate(), input("t1", "hello"))

      assert json_response(conn, 404)
    end

    test "404 for another tenant's agent", %{conn: conn, raw_key: raw_key} do
      stranger = insert_verified_user()
      their_agent = insert_agent(user_id: stranger.id)

      conn = run(conn, raw_key, their_agent.id, input("t1", "hello"))

      assert json_response(conn, 404)
    end

    # The binding is per tenant as well: two users' threads can share an id
    # (a host mints them, not us) without sharing a sandbox.
    test "another tenant's thread of the same name is not resumed", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      stranger = insert_verified_user()
      their_agent = insert_agent(user_id: stranger.id)
      _theirs = bound_conversation(stranger, their_agent, "t1")

      ours = agent_that_cannot_provision(user)

      reject(&ConversationServer.send_prompt/4)

      conn = run(conn, raw_key, ours.id, input("t1", "hello"))

      # We have no conversation on `t1`, so this opens one (and fails for want
      # of a runner) rather than walking into theirs.
      assert json_response(conn, 409)["error"] == "no_runner_online"
    end
  end

  ## ─── The two rules a host depends on ──────────────────────────────────────

  describe "thread mapping" do
    test "channel ids are namespaced, so a host's thread cannot collide with ours" do
      assert AguiController.channel_id("t1") == "agui:t1"
      refute AguiController.channel_id("fountain:team") == "fountain:team"
    end

    test "the standing role opens a new conversation and is not repeated after" do
      assert AguiController.first_prompt("", "hello") == "hello"
      assert AguiController.first_prompt("You are Ada.", "hello") == "You are Ada.\n\nhello"
    end
  end

  describe "the tool bridge (#1202)" do
    test "a host tool the agent calls ends the run as TOOL_CALL events with stopReason tool_calls",
         %{conn: conn, user: user, agent: agent, raw_key: raw_key} do
      conv = bound_conversation(user, agent, "thread-tools")
      stub(ConversationServer, :pending_caller_calls, fn _id -> [] end)

      expect(ConversationServer, :send_prompt, fn conv_id, _prompt, [], _opts ->
        assert [%{"name" => "confirm"}] =
                 Conversations._unsafe_get_conversation!(conv_id).caller_tools

        turn = insert_turn(conv, status: "running")

        Conversations.publish_stage(conv.id, "turn", "started", %{
          turn_id: turn.id,
          turn_number: turn.turn_number
        })

        event =
          insert_log_event(conv,
            kind: "output",
            stream: "acp",
            turn_id: turn.id,
            data: acp(chunk("One sec. "))
          )

        Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, event})

        Conversations.publish_stage(conv.id, "caller_tool", "started", %{
          call_id: "call_7",
          turn_id: turn.id,
          name: "confirm",
          arguments: %{"question" => "delete it?"},
          timeout_ms: 300_000
        })

        :ok
      end)

      body =
        input("thread-tools", "clean up")
        |> Map.put("tools", [
          %{
            "name" => "confirm",
            "description" => "Ask the user",
            "parameters" => %{"type" => "object"}
          }
        ])

      conn = run(conn, raw_key, agent.id, body)
      assert conn.status == 200

      assert types(conn) == [
               "RUN_STARTED",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "TOOL_CALL_START",
               "TOOL_CALL_ARGS",
               "TOOL_CALL_END",
               "RUN_FINISHED"
             ]

      evs = events(conn)

      assert %{"toolCallId" => "call_7", "toolCallName" => "confirm"} =
               Enum.find(evs, &(&1["type"] == "TOOL_CALL_START"))

      assert %{"delta" => args} = Enum.find(evs, &(&1["type"] == "TOOL_CALL_ARGS"))
      assert Jason.decode!(args) == %{"question" => "delete it?"}
      assert %{"result" => %{"stopReason" => "tool_calls"}} = List.last(evs)
    end

    test "a run whose newest messages are tool answers resumes the turn",
         %{conn: conn, user: user, agent: agent, raw_key: raw_key} do
      conv = bound_conversation(user, agent, "thread-tools-2")
      turn = insert_turn(conv, status: "running")
      reject(&ConversationServer.send_prompt/4)

      expect(ConversationServer, :answer_caller_tools, fn conv_id, answers ->
        assert conv_id == conv.id
        assert answers == %{"call_7" => "yes"}

        Conversations.publish_stage(conv.id, "caller_tool", "done", %{
          call_id: "call_7",
          turn_id: turn.id,
          name: "confirm",
          outcome: "answered"
        })

        event =
          insert_log_event(conv,
            kind: "output",
            stream: "acp",
            turn_id: turn.id,
            data: acp(chunk("Deleted."))
          )

        Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, event})
        Conversations.publish_stage(conv.id, "turn", "done", %{turn_id: turn.id})
        {:ok, %{turn_id: turn.id, remaining: []}}
      end)

      body =
        input("thread-tools-2", "ignored",
          messages: [
            %{"role" => "user", "content" => "clean up"},
            %{"role" => "tool", "toolCallId" => "call_7", "content" => "yes"}
          ]
        )

      conn = run(conn, raw_key, agent.id, body)
      assert text(conn) == "Deleted."
      assert %{"result" => %{"turnId" => turn_id}} = List.last(events(conn))
      assert turn_id == turn.id
    end

    test "a user message while calls are pending is refused",
         %{conn: conn, user: user, agent: agent, raw_key: raw_key} do
      _conv = bound_conversation(user, agent, "thread-tools-3")
      stub(ConversationServer, :pending_caller_calls, fn _id -> [%{id: "call_1"}] end)
      reject(&ConversationServer.send_prompt/4)

      conn = run(conn, raw_key, agent.id, input("thread-tools-3", "never mind"))
      assert json_response(conn, 400)["error"] == "tool_calls_pending"
    end
  end
end
