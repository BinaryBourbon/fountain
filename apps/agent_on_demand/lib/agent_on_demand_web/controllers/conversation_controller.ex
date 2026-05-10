defmodule AgentOnDemandWeb.ConversationController do
  use AgentOnDemandWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias AgentOnDemand.Conversations
  alias AgentOnDemand.Conversations.{ConversationServer, LogEvent}
  alias AgentOnDemandWeb.Schemas

  action_fallback AgentOnDemandWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Conversations"])

  operation(:index,
    summary: "List conversations",
    responses: [
      ok: {"Conversations", "application/json", Schemas.ConversationListResponse}
    ]
  )

  def index(conn, _params) do
    current_user = conn.assigns.current_user
    render(conn, :index, conversations: Conversations.list_conversations(current_user.id))
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
    current_user = conn.assigns.current_user

    case Conversations.get_conversation(id, current_user.id) do
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
    current_user = conn.assigns.current_user

    case Conversations.get_conversation(id, current_user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        render(conn, :turns, turns: Conversations.list_turns(id))
    end
  end

  operation(:create,
    summary: "Start a conversation",
    description:
      "Creates a sandbox + conversation pair, starts the runtime in a fresh sprite, " <>
        "and (if `prompt` is supplied) sends it as turn 1. " <>
        "Pass `X-AoD-Parent-Conversation-Id` header to record which conversation spawned this one.",
    request_body: {"Conversation attrs", "application/json", Schemas.ConversationCreateRequest},
    responses: [
      created: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Agent not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, params) do
    current_user = conn.assigns.current_user
    images = decode_images(params["images"])

    parent_header =
      conn
      |> get_req_header("x-aod-parent-conversation-id")
      |> List.first()

    {source, parent_id} = infer_provenance(parent_header)

    params =
      params
      |> Map.put("images", images)
      |> Map.put("source", source)
      |> Map.put("parent_conversation_id", parent_id)

    with {:ok, conv} <- Conversations.start_conversation(params, current_user.id) do
      conn
      |> put_status(:created)
      |> render(:show, conversation: conv)
    end
  end

  @doc """
  Infer the conversation's `source` and `parent_conversation_id` from
  the `X-AoD-Parent-Conversation-Id` header value (or `nil` if absent).
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
    current_user = conn.assigns.current_user
    images = decode_images(params["images"])

    case ConversationServer.send_prompt(id, prompt, images, current_user.id) do
      :ok -> json(conn, %{status: "queued"})
      {:error, :not_running} -> {:error, :not_found}
      {:error, :busy} -> {:error, "conversation_busy"}
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
    current_user = conn.assigns.current_user

    # Ownership check before terminating.
    case Conversations.get_conversation(id, current_user.id) do
      nil ->
        {:error, :not_found}

      _conv ->
        case ConversationServer.terminate(id) do
          :ok -> send_resp(conn, :no_content, "")
          {:error, :not_running} -> send_resp(conn, :no_content, "")
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
    current_user = conn.assigns.current_user

    case Conversations.get_conversation(id, current_user.id) do
      nil ->
        {:error, :not_found}

      _conv ->
        case ConversationServer.interrupt(id) do
          :ok ->
            send_resp(conn, :no_content, "")

          {:error, :not_running} ->
            {:error, :not_found}

          {:error, :idle} ->
            conn |> put_status(:conflict) |> json(%{error: "no_turn_running"})
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
    current_user = conn.assigns.current_user

    case Conversations.get_conversation(id, current_user.id) do
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
      ]
    ],
    responses: [
      ok: {"SSE stream", "text/event-stream", %OpenApiSpex.Schema{type: :string}},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  @heartbeat_ms 15_000

  def stream(conn, %{"conversation_id" => id} = params) do
    current_user = conn.assigns.current_user

    # Ownership check before subscribing. Cross-tenant access returns 404.
    case Conversations.get_conversation(id, current_user.id) do
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

        # Subscribe to the namespaced topic: "conv:<user_id>:<conversation_id>"
        if wait? do
          Phoenix.PubSub.subscribe(
            AgentOnDemand.PubSub,
            "conv:#{current_user.id}:#{id}"
          )
        end

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        {conn, last_id} = replay(conn, id, last_event_id, streams)

        if wait? do
          Process.send_after(self(), :heartbeat, @heartbeat_ms)
          sse_loop(conn, last_id, streams)
        else
          conn
        end
    end
  end

  defp parse_bool_param("false", _default), do: false
  defp parse_bool_param("0", _default), do: false
  defp parse_bool_param("true", _default), do: true
  defp parse_bool_param("1", _default), do: true
  defp parse_bool_param(_, default), do: default

  defp parse_streams_param(nil), do: nil
  defp parse_streams_param(""), do: nil

  defp parse_streams_param(s) when is_binary(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp decode_images(nil), do: []
  defp decode_images([]), do: []

  defp decode_images(images) when is_list(images) do
    Enum.map(images, fn img ->
      b64 = img["data"] || img[:data]
      mt = img["media_type"] || img[:media_type]
      data = Base.decode64!(b64)

      if byte_size(data) > 10 * 1024 * 1024 do
        raise ArgumentError, "Image exceeds 10MB limit"
      end

      %{media_type: mt, data: data}
    end)
  end

  defp parse_last_event_id(nil), do: 0
  defp parse_last_event_id(""), do: 0

  defp parse_last_event_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp replay(conn, conv_id, after_id, streams) do
    conv_id
    |> Conversations.list_log_events(after_id, streams: streams)
    |> Enum.reduce({conn, after_id}, fn ev, {acc_conn, _} ->
      case write_event(acc_conn, ev) do
        {:ok, c} -> {c, ev.id}
        {:error, _} = e -> throw(e)
      end
    end)
  end

  defp event_in_streams?(_ev, nil), do: true

  defp event_in_streams?(%LogEvent{kind: "stage"}, streams),
    do: "stage" in streams

  defp event_in_streams?(%LogEvent{stream: s}, streams) when is_binary(s),
    do: s in streams

  defp event_in_streams?(_ev, _streams), do: false

  defp sse_loop(conn, last_id, streams) do
    receive do
      {:log_event, %LogEvent{id: ev_id} = ev} when ev_id > last_id ->
        cond do
          not event_in_streams?(ev, streams) ->
            sse_loop(conn, ev_id, streams)

          true ->
            case write_event(conn, ev) do
              {:ok, conn} -> sse_loop(conn, ev_id, streams)
              {:error, _} -> conn
            end
        end

      {:log_event, _stale} ->
        sse_loop(conn, last_id, streams)

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, @heartbeat_ms)
            sse_loop(conn, last_id, streams)

          {:error, _} ->
            conn
        end
    after
      60_000 ->
        conn
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
end
