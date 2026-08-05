defmodule FountainWeb.ConversationController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Billing
  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, LogEvent}
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Conversations"])

  operation(:index,
    summary: "List conversations",
    responses: [
      ok: {"Conversations", "application/json", Schemas.ConversationListResponse}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, conversations: Conversations.list_conversations(user.id))
  end

  operation(:show,
    summary: "Get a conversation",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil -> {:error, :not_found}
      conv -> render(conn, :show, conversation: conv)
    end
  end

  operation(:turns,
    summary: "List turns in a conversation",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Turns", "application/json", Schemas.TurnListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def turns(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        # Ownership: established by the scoped get_conversation above.
        render(conn, :turns, turns: Conversations._unsafe_list_turns(id))
    end
  end

  @default_event_limit 100
  @max_event_limit 1000

  operation(:events,
    summary: "List a conversation's log events",
    description:
      "The read-model behind the SSE stream. Same rows, same fields, as JSON — " <>
        "fetching or archiving a conversation's output no longer requires an SSE " <>
        "parser. Oldest first, cursor-paginated: pass the previous page's " <>
        "`meta.next_cursor` as `after`. SSE remains the tail/follow mechanism.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      streams: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated allow-list of `stdout`, `stderr`, `stage`. " <>
            "Same semantics as the SSE route; omitted means everything."
      ],
      after: [
        in: :query,
        type: :integer,
        required: false,
        description: "Return events with an id greater than this. Defaults to 0."
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size, 1..#{@max_event_limit}. Defaults to #{@default_event_limit}."
      ]
    ],
    responses: [
      ok: {"Log events", "application/json", Schemas.LogEventListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def events(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        limit = parse_limit(params["limit"])
        after_id = parse_after(params["after"])
        streams = parse_streams_param(params["streams"])

        # Ownership: established by the scoped get_conversation above.
        # One extra row decides has_more without a second count query.
        events =
          Conversations._unsafe_list_log_events(id, after_id,
            streams: streams,
            limit: limit + 1
          )

        {page, has_more?} = split_page(events, limit)

        render(conn, :events, events: page, has_more: has_more?, limit: limit)
    end
  end

  defp split_page(events, limit) do
    case Enum.split(events, limit) do
      {page, []} -> {page, false}
      {page, _extra} -> {page, true}
    end
  end

  defp parse_limit(nil), do: @default_event_limit
  defp parse_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_event_limit)

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> parse_limit(n)
      :error -> @default_event_limit
    end
  end

  defp parse_after(nil), do: 0
  defp parse_after(n) when is_integer(n) and n > 0, do: n
  defp parse_after(n) when is_integer(n), do: 0
  defp parse_after(s) when is_binary(s), do: s |> parse_last_event_id() |> max(0)

  operation(:create,
    summary: "Start a conversation",
    description:
      "Creates a sandbox + conversation pair, starts the runtime in a fresh sprite, " <>
        "and (if `prompt` is supplied) sends it as turn 1. " <>
        "Pass `X-Fountain-Parent-Conversation-Id` header to record which conversation spawned this one. " <>
        "Legacy `X-AoD-Parent-Conversation-Id` is still accepted for sprites provisioned before the rename.",
    request_body: {"Conversation attrs", "application/json", Schemas.ConversationCreateRequest},
    responses: [
      created: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Agent not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError},
      payment_required:
        {"Subscription required", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             error: %OpenApiSpex.Schema{type: :string},
             upgrade_url: %OpenApiSpex.Schema{type: :string}
           }
         }}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, images} <- decode_images(params["images"]) do
      create_with_images(conn, params, user, images)
    end
  end

  defp create_with_images(conn, params, user, images) do
    parent_header =
      List.first(get_req_header(conn, "x-fountain-parent-conversation-id")) ||
        List.first(get_req_header(conn, "x-aod-parent-conversation-id"))

    {source, parent_id} = infer_provenance(parent_header)

    params =
      params
      |> Map.put("images", images)
      |> Map.put("source", source)
      |> Map.put("parent_conversation_id", parent_id)
      |> Map.put("user_id", user.id)

    with :ok <- gate_subscription(user),
         {:ok, conv} <- Conversations.start_conversation(params) do
      conn
      |> put_status(:created)
      |> render(:show, conversation: conv)
    else
      {:error, :subscription_required} ->
        conn
        |> put_status(402)
        |> json(%{error: "subscription_required", upgrade_url: "/account/billing"})

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Infer the conversation's `source` and `parent_conversation_id` from
  the `X-Fountain-Parent-Conversation-Id` (or legacy `X-AoD-Parent-Conversation-Id`)
  header value (or `nil` if absent).

  Pure function so the inference logic can be unit-tested without
  going through the full `Conversations.start_conversation/1` pipeline
  (which provisions a real Sprite).
  """
  @spec infer_provenance(String.t() | nil) :: {String.t(), String.t() | nil}
  def infer_provenance(parent_header) do
    case parent_header do
      id when is_binary(id) and byte_size(id) > 0 -> {"agent", id}
      _ -> {"api", nil}
    end
  end

  operation(:prompt,
    summary: "Send another prompt",
    description:
      "Queues a new turn. If the ConversationServer has been GC'd (e.g. across a " <>
        "BEAM restart) a fresh sprite is provisioned and the runtime resumes via its " <>
        "session id.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    request_body: {"Prompt", "application/json", Schemas.PromptRequest},
    responses: [
      ok: {"Queued", "application/json", Schemas.PromptResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      bad_request: {"Busy", "application/json", Schemas.Error}
    ]
  )

  def prompt(conn, %{"conversation_id" => id, "prompt" => prompt} = params) do
    user = conn.assigns.current_user

    with {:ok, images} <- decode_images(params["images"]) do
      do_prompt(conn, id, prompt, user, images)
    end
  end

  defp do_prompt(conn, id, prompt, user, images) do
    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case ConversationServer.send_prompt(id, prompt, images) do
          :ok ->
            json(conn, %{status: "queued"})

          {:error, :not_running} ->
            {:error, :not_found}

          {:error, :busy} ->
            {:error, "conversation_busy"}

          # Everything else renders via the FallbackController. This case has
          # had error shapes threaded through it by hand four times (#212's
          # 402, then :gone / :no_agent / changeset in #332), and each one it
          # was missing was a CaseClauseError 500. The fallback owns the
          # error → status mapping; new shapes land there, not here.
          {:error, _} = err ->
            err
        end
    end
  end

  operation(:terminate,
    summary: "Terminate a conversation",
    description:
      "Tears down the sprite and marks the conversation `terminated`. Idempotent " <>
        "for already-dead conversations.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Terminated",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def terminate(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case ConversationServer.terminate(id) do
          :ok -> send_resp(conn, :no_content, "")
          {:error, :not_running} -> {:error, :not_found}
          # :provisioning and future shapes render via the FallbackController.
          {:error, _} = err -> err
        end
    end
  end

  operation(:interrupt,
    summary: "Interrupt the running turn",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Interrupted",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"No turn running", "application/json", Schemas.Error}
    ]
  )

  def interrupt(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case ConversationServer.interrupt(id) do
          :ok ->
            send_resp(conn, :no_content, "")

          {:error, :not_running} ->
            {:error, :not_found}

          {:error, :idle} ->
            conn |> put_status(:conflict) |> json(%{error: "no_turn_running"})

          # :provisioning and future shapes render via the FallbackController.
          {:error, _} = err ->
            err
        end
    end
  end

  operation(:delete,
    summary: "Delete a conversation",
    description:
      "Tears down the sprite if alive, then deletes the conversation row " <>
        "(cascades to turns and log events).",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        {:ok, _} = Conversations.delete_conversation(conv)
        send_resp(conn, :no_content, "")
    end
  end

  operation(:stream,
    summary: "Stream log events (SSE)",
    description:
      "Server-Sent Events stream of the conversation's log events. The `Last-Event-ID` " <>
        "request header resumes from a known event id; missed events are replayed before " <>
        "the live tail begins. Keep-alive heartbeats every 15s as `: heartbeat` comments.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      "Last-Event-ID": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Resume after this event id (integer as string). " <>
            "Missing or unparseable values are treated as 0."
      ],
      # Both load-bearing in the bundled SKILL.md files and undocumented here
      # until now.
      streams: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated subset of `stdout`, `stderr`, `stage`. " <>
            "Omitted or empty means all three."
      ],
      wait: [
        in: :query,
        type: :string,
        required: false,
        description:
          "`false`/`0` drains the buffered events and closes immediately, " <>
            "rather than holding the connection open for the live tail. " <>
            "Defaults to true."
      ]
    ],
    responses: [
      ok: {"SSE stream", "text/event-stream", %OpenApiSpex.Schema{type: :string}},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  # Both read from application env so the loop can be driven at test speed.
  # Waiting 15s for a heartbeat and 60s for the idle exit is why none of this
  # had tests: the timings are the behaviour, and the behaviour was unreachable.
  @default_heartbeat_ms 15_000
  @default_idle_timeout_ms 60_000

  defp heartbeat_ms,
    do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  defp idle_timeout_ms,
    do: Application.get_env(:fountain, :sse_idle_timeout_ms, @default_idle_timeout_ms)

  def stream(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        last_event_id =
          conn
          |> get_req_header("last-event-id")
          |> List.first()
          |> parse_last_event_id()

        streams = parse_streams_param(params["streams"])
        wait? = parse_bool_param(params["wait"], true)

        if wait? do
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{id}")
        end

        # A ConversationServer that dies without publishing a terminal
        # stage (a crash, a Horde rebalance, a deploy) would otherwise
        # leave this stream heartbeating forever with no data and no
        # reason to reconnect. Monitoring is best-effort: no server just
        # means an idle/finished conversation being drained from history.
        # The ref is matched exactly in sse_loop — this process holds other
        # monitors (DB ownership among them) whose :DOWN messages must not
        # end the stream.
        monitor_ref =
          if wait? do
            case ConversationServer.whereis(id) do
              pid when is_pid(pid) -> Process.monitor(pid)
              _ -> nil
            end
          end

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Replay buffered events the client missed.
        {status, conn, last_id} = replay(conn, id, last_event_id, streams)

        if wait? and status == :ok do
          Process.send_after(self(), :heartbeat, heartbeat_ms())
          sse_loop(conn, last_id, streams, monitor_ref)
        else
          # `?wait=false` → close immediately after replay. Useful when
          # the caller already knows the conversation is finished and
          # just wants to drain the history quickly (no 60s heartbeat
          # window before curl `--max-time` fires).
          conn
        end
    end
  end

  defp parse_bool_param("false", _default), do: false
  defp parse_bool_param("0", _default), do: false
  defp parse_bool_param("true", _default), do: true
  defp parse_bool_param("1", _default), do: true
  defp parse_bool_param(_, default), do: default

  # `?streams=stdout,stderr,stage` — comma-separated allow-list. Empty /
  # missing param = no filter (everything goes through).
  defp parse_streams_param(nil), do: nil
  defp parse_streams_param(""), do: nil

  defp parse_streams_param(s) when is_binary(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  # Validation, decode and size cap live in FountainWeb.PromptImages so the
  # LiveView prompt path applies exactly the same checks.
  defp decode_images(images), do: FountainWeb.PromptImages.decode(images)

  defp parse_last_event_id(nil), do: 0
  defp parse_last_event_id(""), do: 0

  defp parse_last_event_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Returns `{:ok, conn, last_id}`, or `{:closed, conn, last_id}` when the
  # client went away mid-replay — a routine disconnect (Ctrl-C on a curl, a
  # closed tab, an EventSource reconnect against a long backlog), not an
  # error. This used to `throw` the chunk error with no catch anywhere in
  # the module, producing a crash report and a Sentry event per disconnect.
  defp replay(conn, conv_id, after_id, streams) do
    # Ownership: only called from stream/2, after its scoped get_conversation.
    conv_id
    |> Conversations._unsafe_list_log_events(after_id, streams: streams)
    |> Enum.reduce_while({:ok, conn, after_id}, fn ev, {:ok, acc_conn, last_id} ->
      case write_event(acc_conn, ev) do
        {:ok, c} -> {:cont, {:ok, c, ev.id}}
        {:error, _} -> {:halt, {:closed, acc_conn, last_id}}
      end
    end)
  end

  # Match a freshly-broadcast event against the same allow-list the
  # historical replay used.
  defp event_in_streams?(_ev, nil), do: true

  defp event_in_streams?(%LogEvent{kind: "stage"}, streams),
    do: "stage" in streams

  defp event_in_streams?(%LogEvent{stream: s}, streams) when is_binary(s),
    do: s in streams

  defp event_in_streams?(_ev, _streams), do: false

  defp sse_loop(conn, last_id, streams, monitor_ref) do
    receive do
      {:log_event, %LogEvent{id: ev_id} = ev} when ev_id > last_id ->
        cond do
          not event_in_streams?(ev, streams) ->
            sse_loop(conn, ev_id, streams, monitor_ref)

          true ->
            case write_event(conn, ev) do
              {:ok, conn} -> sse_loop(conn, ev_id, streams, monitor_ref)
              {:error, _} -> conn
            end
        end

      {:log_event, _stale} ->
        sse_loop(conn, last_id, streams, monitor_ref)

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            sse_loop(conn, last_id, streams, monitor_ref)

          {:error, _} ->
            conn
        end

      {:DOWN, ^monitor_ref, :process, _pid, reason} when is_reference(monitor_ref) ->
        # The conversation server died without publishing a terminal stage.
        # Say so and close, so the client reconnects (and, if the server was
        # rehydrated elsewhere, resumes) instead of receiving heartbeats
        # forever on a topic nothing will publish to again.
        write_server_down_event(conn, reason)
    after
      idle_timeout_ms() ->
        # Long quiet — exit cleanly so the client reconnects.
        conn
    end
  end

  # Synthetic (not persisted, so no SSE id — it must not disturb
  # Last-Event-ID resume) stage event telling the client why the stream is
  # closing. Same payload shape as write_event/2. A clean shutdown or Horde
  # handoff is the stage reaching its end ("done"); anything else is a crash
  # ("failed") — the stage vocabulary clients already switch on.
  defp write_server_down_event(conn, reason) do
    state =
      case reason do
        :normal -> "done"
        :shutdown -> "done"
        {:shutdown, _} -> "done"
        _ -> "failed"
      end

    payload =
      Jason.encode!(%{
        kind: "stage",
        stream: nil,
        data:
          Jason.encode!(%{
            reason: inspect(reason),
            message: "conversation server exited — reconnect to resume streaming"
          }),
        stage: "server",
        state: state,
        turn_id: nil,
        ts: DateTime.utc_now()
      })

    case Plug.Conn.chunk(conn, "event: stage\ndata: #{payload}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp write_event(conn, %LogEvent{} = ev) do
    payload =
      %{
        kind: ev.kind,
        stream: ev.stream,
        data: ev.data,
        stage: ev.stage,
        state: ev.state,
        turn_id: ev.turn_id,
        ts: ev.inserted_at
      }
      |> Jason.encode!()

    chunk = "id: #{ev.id}\nevent: #{ev.kind}\ndata: #{payload}\n\n"
    Plug.Conn.chunk(conn, chunk)
  end

  # ── Phase-3-billing helpers ────────────────────────────────────────────────

  # Wraps assert_active! so it fits into the `with` pipeline without propagating
  # the raw exception. Returns {:error, :subscription_required} for the else
  # clause to render a structured 402 response.
  defp gate_subscription(user) do
    Billing.assert_active!(user)
    :ok
  rescue
    Billing.SubscriptionRequiredError -> {:error, :subscription_required}
  end
end
