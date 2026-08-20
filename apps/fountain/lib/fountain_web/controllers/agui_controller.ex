defmodule FountainWeb.AguiController do
  @moduledoc """
  A Fountain agent answering as an [AG-UI](https://github.com/ag-ui-protocol/ag-ui)
  endpoint.

  `POST /api/agui/:agent_id` takes the protocol's `RunAgentInput` and answers
  with its SSE event stream, so an AG-UI host can register a Fountain agent
  knowing nothing about Fountain's own API — one URL and a bearer token. The
  host this was built against is CopilotKit's OpenBot, where a "Bot" is exactly
  that: an endpoint speaking AG-UI. See `docs/integrations/openbot.md`.

  ## The thread is the conversation

  An AG-UI host holds the transcript and replays the whole message list on every
  run, expecting the endpoint to keep no memory of its own. A Fountain
  conversation is the opposite: the sandbox holds the context, and feeding it
  back its own transcript each turn would be both wrong and expensive.

  So the thread is *mapped* to a conversation rather than replayed into one.
  `threadId` becomes the channel binding `agui:<threadId>` — the same mechanism
  the team page resumes on (#774) — and only the newest user message of each run
  is sent as a prompt. The first run on a thread opens the conversation; every
  later run prompts the one already bound. A host that starts a new thread gets
  a new sandbox, which is what starting a new channel should mean.

  The standing role (the host's `system`/`developer` messages) rides along with
  the first prompt only. Editing it afterwards reaches new threads, not the
  sandbox that already booted with it.

  ## One run is one turn

  `RUN_STARTED` goes out immediately, then the turn's log events are translated
  as they arrive, then `RUN_FINISHED` when the turn ends (`RUN_ERROR` if it
  failed). `text` blocks stream as the assistant's message. Everything else the
  turn does — `thinking`, `tool_use`, `tool_result`, and the lifecycle stages,
  because provisioning a fresh sandbox takes a minute and silence reads as a
  hang — streams as AG-UI *thinking* events, which a host renders as reasoning.

  Nothing here is emitted as an AG-UI **tool call**. On this protocol a tool call
  means "host, run this and send me the result", and that is not what happened: a
  Fountain agent ran its own tool, inside its own sandbox, and already has the
  result. Reporting it as a call would ask the host to execute something twice
  and leave the run waiting for a result it will never be sent. Bridging the
  host's tools *into* the sandbox is the other half of the integration and is
  deliberately not in this one.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.{Blocks, ConversationServer, LogEvent}
  alias FountainWeb.Audited

  action_fallback FountainWeb.FallbackController

  tags(["Integrations"])

  @run_input %OpenApiSpex.Schema{
    type: :object,
    title: "RunAgentInput",
    description:
      "The AG-UI run envelope, as the protocol defines it. Extra fields are accepted " <>
        "and ignored: only `threadId`, `runId` and `messages` are read.",
    properties: %{
      threadId: %OpenApiSpex.Schema{
        type: :string,
        description: "The host's thread. Bound to one Fountain conversation as `agui:<threadId>`."
      },
      runId: %OpenApiSpex.Schema{type: :string, description: "This run. Echoed in the events."},
      messages: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :object},
        description:
          "The thread so far. The newest `user` message becomes the prompt; " <>
            "`system`/`developer` messages become the standing role of a new conversation."
      },
      tools: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :object},
        description: "Accepted and ignored — see the module doc on why no tool call is emitted."
      },
      state: %OpenApiSpex.Schema{type: :object},
      context: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
      forwardedProps: %OpenApiSpex.Schema{type: :object}
    },
    required: [:threadId, :runId, :messages]
  }

  operation(:run,
    summary: "Run an agent over AG-UI (SSE)",
    description:
      "Answers a `RunAgentInput` with the AG-UI event stream: `RUN_STARTED`, the turn's " <>
        "output as `TEXT_MESSAGE_*` and `THINKING_*` events, then `RUN_FINISHED` or " <>
        "`RUN_ERROR`. Each SSE message is `data: {\"type\": ...}`, as the reference " <>
        "encoder writes it.\n\n" <>
        "`threadId` binds to a conversation (`agui:<threadId>`): the first run opens one, " <>
        "later runs prompt it. Only the newest user message is sent — the agent's memory " <>
        "lives in its sandbox, not in the replayed transcript.\n\n" <>
        "Errors before the stream opens are ordinary JSON responses (404 for an unknown " <>
        "agent, 402 without a subscription); once it is open, failure arrives as `RUN_ERROR`.",
    parameters: [
      agent_id: [in: :path, type: :string, required: true, description: "The agent to run."],
      activity: [
        in: :query,
        type: :string,
        required: false,
        description:
          "`off` streams the reply text only. Default `thinking`: tool use and lifecycle " <>
            "stages are relayed as AG-UI thinking events too, which is also what keeps a " <>
            "host's stall watchdog fed while a sandbox provisions."
      ]
    ],
    request_body: {"AG-UI run input", "application/json", @run_input},
    responses: [
      ok: {"AG-UI event stream", "text/event-stream", %OpenApiSpex.Schema{type: :string}},
      bad_request: {"Malformed run input", "application/json", FountainWeb.Schemas.Error},
      not_found: {"No such agent", "application/json", FountainWeb.Schemas.Error}
    ]
  )

  def run(conn, %{"agent_id" => agent_id} = params) do
    user = conn.assigns.current_user

    with {:ok, thread_id} <- require_string(params["threadId"], "threadId"),
         {:ok, run_id} <- require_string(params["runId"], "runId"),
         messages = List.wrap(params["messages"]),
         {:ok, prompt} <- last_user_message(messages),
         {:ok, conv, since} <- open(conn, agent_id, user, thread_id, prompt, messages) do
      stream(conn, conv, thread_id, run_id, since, params)
    end
  end

  ## ─── Opening the conversation ─────────────────────────────────────────────

  # Bind, prompt, and hand back the log-event id everything after which belongs
  # to this run. Subscription happens before the prompt is sent, and the caller
  # replays from `since` anyway, so no event can fall between the two.
  defp open(conn, agent_id, user, thread_id, prompt, messages) do
    attrs = %{
      "agent_id" => agent_id,
      "user_id" => user.id,
      "channel_id" => channel_id(thread_id),
      "source" => "api",
      "prompt" => first_prompt(standing_role(messages), prompt)
    }

    case Conversations.start_or_resume_conversation(attrs, Audited.attribution(conn)) do
      {:ok, conv, :created} ->
        subscribe(conv.id)
        # A conversation opened by this request has no earlier events to skip.
        {:ok, conv, 0}

      {:ok, conv, :resumed} ->
        subscribe(conv.id)

        # Ownership: established by start_or_resume_conversation directly
        # above, which resolves the conversation scoped by user_id.
        since = Conversations._unsafe_latest_log_event_id(conv.id)

        case ConversationServer.send_prompt(conv.id, prompt, [], Audited.attribution(conn)) do
          :ok -> {:ok, conv, since}
          {:error, :busy} -> {:error, "conversation_busy"}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp subscribe(conv_id), do: Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv_id}")

  @doc """
  The channel a host's thread binds to.

  Namespaced because a channel id is a shared vocabulary — `fountain:team` is
  the team page's — and a bare thread id from someone else's product must not
  be able to collide with one of ours.
  """
  @spec channel_id(String.t()) :: String.t()
  def channel_id(thread_id), do: "agui:" <> thread_id

  @doc """
  The prompt a brand-new conversation opens with: the standing role, then the
  message.

  The host re-sends its role on every run. It is only of use on the first,
  where it is what the sandbox boots knowing; afterwards the agent has it, and
  repeating it every turn would be noise in the transcript and tokens on the
  bill. The cost is that editing a role in the host reaches new threads, not
  the sandbox that already booted with it.
  """
  @spec first_prompt(String.t(), String.t()) :: String.t()
  def first_prompt("", prompt), do: prompt
  def first_prompt(role, prompt), do: role <> "\n\n" <> prompt

  defp standing_role(messages) do
    messages
    |> Enum.filter(&(is_map(&1) and &1["role"] in ["system", "developer"]))
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(is_map(&1) and &1["role"] == "user"))
    |> case do
      nil -> {:error, "no user message in this run"}
      message -> non_empty(content_text(message), "the newest user message has no text")
    end
  end

  defp non_empty("", reason), do: {:error, reason}
  defp non_empty(text, _reason), do: {:ok, text}

  # AG-UI carries message content as a string. Multi-part content is not in the
  # 0.0.57 schema but costs two lines to survive, and a host that sends it would
  # otherwise look to the user like an agent that ignored them.
  defp content_text(%{"content" => content}) when is_binary(content), do: content

  defp content_text(%{"content" => parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp content_text(_), do: ""

  defp require_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp require_string(_value, field), do: {:error, "#{field} is required"}

  ## ─── The stream ───────────────────────────────────────────────────────────

  @default_heartbeat_ms 15_000
  @default_quiet_timeout_ms 600_000

  defp heartbeat_ms, do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  # How long the conversation may produce nothing at all before the run is
  # abandoned. Not a ceiling on the turn: any log event resets it, and a working
  # agent emits them constantly. It is the backstop for a conversation that
  # stops existing without saying so.
  defp quiet_timeout_ms,
    do: Application.get_env(:fountain, :agui_quiet_timeout_ms, @default_quiet_timeout_ms)

  defp stream(conn, conv, thread_id, run_id, since, params) do
    # Best-effort, exactly as in the log stream: no server means a conversation
    # that is idle or already finished, which the replay below still covers.
    monitor_ref =
      case ConversationServer.whereis(conv.id) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    state = %{
      conn: conn,
      conv_id: conv.id,
      runtime: conv.runtime,
      thread_id: thread_id,
      run_id: run_id,
      last_id: since,
      turn_id: nil,
      text_id: nil,
      thinking?: false,
      seq: 0,
      activity?: params["activity"] != "off",
      monitor_ref: monitor_ref,
      deadline: now_ms() + quiet_timeout_ms()
    }

    case emit(state, "RUN_STARTED", %{threadId: thread_id, runId: run_id}) do
      {:ok, state} ->
        Process.send_after(self(), :heartbeat, heartbeat_ms())

        case replay(state, since) do
          {:ok, state} -> loop(state)
          {_halted, state} -> state.conn
        end

      {:closed, state} ->
        state.conn
    end
  end

  # Events written between the prompt and the subscription — for a fresh
  # conversation, everything provisioning has done so far.
  defp replay(state, since) do
    # Ownership: the conversation was resolved scoped by user_id in open/6,
    # which is the only caller path into this stream.
    state.conv_id
    |> Conversations._unsafe_list_log_events(since)
    |> Enum.reduce_while({:ok, state}, fn ev, {:ok, state} ->
      case handle_event(%{state | last_id: ev.id}, ev) do
        {:ok, state} -> {:cont, {:ok, state}}
        halted -> {:halt, halted}
      end
    end)
  end

  defp loop(state) do
    case receive_next(state) do
      {:event, %LogEvent{id: id} = ev} ->
        case handle_event(%{state | last_id: id, deadline: now_ms() + quiet_timeout_ms()}, ev) do
          {:ok, state} -> loop(state)
          {_halted, state} -> state.conn
        end

      :stale ->
        loop(state)

      :heartbeat ->
        # A comment, not an event: it keeps the connection (and a host's
        # silence watchdog) alive without appearing in the protocol.
        case Plug.Conn.chunk(state.conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            loop(%{state | conn: conn})

          {:error, _} ->
            state.conn
        end

      {:server_down, reason} ->
        {_, state} =
          fail(state, "the conversation stopped running (#{inspect(reason)}) — retry to resume")

        state.conn

      :quiet ->
        {_, state} = fail(state, "the conversation went quiet; nothing arrived for the timeout")
        state.conn
    end
  end

  defp receive_next(state) do
    ref = state.monitor_ref

    receive do
      {:log_event, %LogEvent{id: id} = ev} when id > state.last_id -> {:event, ev}
      {:log_event, _stale} -> :stale
      :heartbeat -> :heartbeat
      {:DOWN, ^ref, :process, _pid, reason} when is_reference(ref) -> {:server_down, reason}
    after
      max(state.deadline - now_ms(), 0) -> :quiet
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  ## ─── Log events → AG-UI events ────────────────────────────────────────────

  # The turn this run is waiting for. A conversation can only run one at a
  # time, so the first `started` after our cursor is ours.
  defp handle_event(%{turn_id: nil} = state, %LogEvent{stage: "turn", state: "started"} = ev) do
    case meta(ev)["turn_id"] do
      turn_id when is_binary(turn_id) -> {:ok, %{state | turn_id: turn_id}}
      _ -> {:ok, state}
    end
  end

  defp handle_event(%{turn_id: turn_id} = state, %LogEvent{stage: "turn", state: state_name} = ev)
       when is_binary(turn_id) and state_name in ~w(done failed interrupted) do
    if meta(ev)["turn_id"] == turn_id do
      finish(state, state_name, meta(ev))
    else
      {:ok, state}
    end
  end

  defp handle_event(%{turn_id: turn_id} = state, %LogEvent{kind: "output", turn_id: turn_id} = ev)
       when is_binary(turn_id) do
    ev
    |> Blocks.for_event(state.runtime)
    |> Enum.reduce_while({:ok, state}, fn block, {:ok, state} ->
      case apply_block(state, block) do
        {:ok, state} -> {:cont, {:ok, state}}
        halted -> {:halt, halted}
      end
    end)
  end

  # A stage that failed before any turn started — provisioning died, the
  # sandbox never came up. Nothing else will arrive, so end the run rather than
  # wait out the quiet timeout.
  defp handle_event(%{turn_id: nil} = state, %LogEvent{kind: "stage", state: "failed"} = ev) do
    reason = meta(ev)["reason"] || meta(ev)["message"] || "no reason given"
    fail(state, "#{ev.stage} failed: #{reason}")
  end

  # Everything else — provision/setup/sandbox progress — is worth showing while
  # a first run waits for its sandbox, and worth nothing after that.
  defp handle_event(%{turn_id: nil} = state, %LogEvent{kind: "stage"} = ev) do
    activity(state, "#{ev.stage}: #{ev.state}\n")
  end

  defp handle_event(state, _ev), do: {:ok, state}

  defp meta(%LogEvent{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp meta(_ev), do: %{}

  defp apply_block(state, %{kind: :text, body: body}) when is_binary(body) and body != "",
    do: write(state, :text, body)

  defp apply_block(state, %{kind: :thinking, body: body}) when is_binary(body) and body != "",
    do: activity(state, body)

  defp apply_block(state, %{kind: :tool_use} = block),
    do: activity(state, "→ #{block[:name] || "tool"}#{summary(block)}\n")

  defp apply_block(state, %{kind: :tool_result, error?: true}), do: activity(state, "← failed\n")
  defp apply_block(state, %{kind: :tool_result}), do: activity(state, "← ok\n")

  defp apply_block(state, %{kind: :error, body: body}) when is_binary(body) and body != "",
    do: activity(state, "error: #{body}\n")

  defp apply_block(state, _block), do: {:ok, state}

  defp summary(%{summary: summary}) when is_binary(summary) and summary != "", do: " #{summary}"
  defp summary(_block), do: ""

  ## ─── Emitting ─────────────────────────────────────────────────────────────

  # Text goes to the assistant message; everything else to the thinking region.
  # The two cannot be open at once, so each opens by closing the other.
  defp write(state, :text, delta) do
    with {:ok, state} <- close_thinking(state),
         {:ok, state} <- open_text(state) do
      emit(state, "TEXT_MESSAGE_CONTENT", %{messageId: state.text_id, delta: delta})
    end
  end

  defp write(state, :thinking, delta) do
    with {:ok, state} <- close_text(state),
         {:ok, state} <- open_thinking(state) do
      emit(state, "THINKING_TEXT_MESSAGE_CONTENT", %{delta: delta})
    end
  end

  defp activity(%{activity?: false} = state, _delta), do: {:ok, state}
  defp activity(state, delta), do: write(state, :thinking, delta)

  defp open_text(%{text_id: nil} = state) do
    message_id = "msg_#{state.run_id}_#{state.seq}"

    with {:ok, state} <-
           emit(state, "TEXT_MESSAGE_START", %{messageId: message_id, role: "assistant"}) do
      {:ok, %{state | text_id: message_id, seq: state.seq + 1}}
    end
  end

  defp open_text(state), do: {:ok, state}

  defp close_text(%{text_id: nil} = state), do: {:ok, state}

  defp close_text(state) do
    with {:ok, state} <- emit(state, "TEXT_MESSAGE_END", %{messageId: state.text_id}) do
      {:ok, %{state | text_id: nil}}
    end
  end

  defp open_thinking(%{thinking?: false} = state) do
    with {:ok, state} <- emit(state, "THINKING_START", %{}),
         {:ok, state} <- emit(state, "THINKING_TEXT_MESSAGE_START", %{}) do
      {:ok, %{state | thinking?: true}}
    end
  end

  defp open_thinking(state), do: {:ok, state}

  defp close_thinking(%{thinking?: false} = state), do: {:ok, state}

  defp close_thinking(state) do
    with {:ok, state} <- emit(state, "THINKING_TEXT_MESSAGE_END", %{}),
         {:ok, state} <- emit(state, "THINKING_END", %{}) do
      {:ok, %{state | thinking?: false}}
    end
  end

  defp finish(state, "failed", meta) do
    fail(state, meta["reason"] || "the turn failed")
  end

  defp finish(state, state_name, meta) do
    with {:ok, state} <- interrupted_note(state, state_name),
         {:ok, state} <- close_text(state),
         {:ok, state} <- close_thinking(state),
         {:ok, state} <-
           emit(state, "RUN_FINISHED", %{
             threadId: state.thread_id,
             runId: state.run_id,
             result: %{
               conversationId: state.conv_id,
               turnId: state.turn_id,
               stopReason: stop_reason(meta)
             }
           }) do
      {:done, state}
    end
  end

  defp interrupted_note(state, "interrupted"), do: activity(state, "\n(interrupted)\n")
  defp interrupted_note(state, _state_name), do: {:ok, state}

  defp stop_reason(meta), do: meta["stop_reason"] || meta["reason"]

  # RUN_ERROR is terminal for the protocol, so both channels close first: a
  # host that renders a half-open message would keep it spinning forever.
  defp fail(state, message) do
    with {:ok, state} <- close_text(state),
         {:ok, state} <- close_thinking(state),
         {:ok, state} <- emit(state, "RUN_ERROR", %{message: message}) do
      {:done, state}
    end
  end

  # One SSE message per event, the type inside the JSON — the shape the
  # reference AG-UI encoder writes and every client parses.
  defp emit(state, type, fields) do
    payload = fields |> Map.put(:type, type) |> Jason.encode!()

    case Plug.Conn.chunk(state.conn, "data: #{payload}\n\n") do
      {:ok, conn} ->
        {:ok, %{state | conn: conn}}

      # The host hung up mid-run. Routine (a closed tab, an abandoned run), and
      # nothing is left to say to a socket that is gone.
      {:error, _reason} ->
        {:closed, state}
    end
  end
end
