defmodule FountainWeb.EventsController do
  @moduledoc """
  `GET /api/events/stream`: every conversation of the caller on one SSE
  connection (#813) — what a client that shows a conversation list with live
  status and unread dots needs, instead of one socket per conversation.

  Same loop shape as `TeamController.stream/2`: subscribe to each followed
  conversation's `conv:<id>` topic and to the user's `sidebar:<id>` topic;
  the latter is pinged on every change to the list (a conversation created,
  titled, read, deleted — and once per output chunk from ConversationServer),
  so it is debounced here into one `conversations` event and one re-follow
  pass per quiet second at most.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.LogEvent

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Conversations"])

  operation(:stream,
    summary: "Stream every conversation's events (SSE)",
    description:
      "One `text/event-stream` carrying the log events of every conversation the " <>
        "caller owns that is not finished, each payload the shape of " <>
        "`GET /api/conversations/:id/stream` plus `conversation_id`. A `conversations` " <>
        "event (data `{reason: changed}`) is sent, debounced, when the list changes — " <>
        "created, titled, read, deleted, finished — and the stream follows a new " <>
        "conversation on its own; the client re-lists. `Last-Event-ID` replays what was " <>
        "missed across every followed conversation. `?streams=` filters as elsewhere; " <>
        "`?blocks=true` adds server-parsed blocks. Heartbeats every 15 s; closes after " <>
        "60 s idle so the client reconnects. The first byte is a `: connected` comment.",
    parameters: [
      "Last-Event-ID": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Resume after this event id (integer as string). " <>
            "Missing or unparseable values are treated as 0."
      ],
      streams: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated stream allow-list (`stdout,stderr,acp,stage`)."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Add `blocks` to each event payload. Defaults to false."
      ]
    ],
    responses: [
      ok: {"SSE stream", "text/event-stream", %OpenApiSpex.Schema{type: :string}}
    ]
  )

  @default_heartbeat_ms 15_000
  @default_idle_timeout_ms 60_000
  @refollow_debounce_ms 1_000

  defp heartbeat_ms,
    do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  defp idle_timeout_ms,
    do: Application.get_env(:fountain, :sse_idle_timeout_ms, @default_idle_timeout_ms)

  def stream(conn, params) do
    user_id = conn.assigns.current_user.id
    last_event_id = conn |> get_req_header("last-event-id") |> List.first() |> parse_id()
    streams = parse_streams(params["streams"])
    blocks? = params["blocks"] in [true, "true", "1"]

    Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user_id}")
    followed = follow(user_id, %{})

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # A first byte straight away — a buffering proxy (Cloudflare) would
    # otherwise hold the headers until the first heartbeat.
    conn =
      case Plug.Conn.chunk(conn, ": connected\n\n") do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end

    state = %{
      user_id: user_id,
      followed: followed,
      last_id: last_event_id,
      streams: streams,
      blocks?: blocks?,
      refollow_pending?: false
    }

    case replay(conn, state) do
      {:ok, conn, last_id} ->
        Process.send_after(self(), :heartbeat, heartbeat_ms())
        sse_loop(conn, %{state | last_id: last_id})

      {:closed, conn, _} ->
        conn
    end
  end

  # conversation_id → runtime for every conversation still worth following.
  # Finished ones publish nothing; a conversation that finishes while
  # followed simply goes quiet. Never unsubscribed — the process ends with
  # the request.
  defp follow(user_id, followed) do
    user_id
    |> Conversations.list_conversations()
    |> Enum.reject(&(&1.status in ["terminated", "failed"]))
    |> Enum.reduce(followed, fn conv, acc ->
      unless Map.has_key?(acc, conv.id) do
        Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
      end

      Map.put(acc, conv.id, conv.runtime)
    end)
  end

  defp replay(conn, %{last_id: 0}), do: {:ok, conn, 0}

  defp replay(conn, state) do
    # Ownership: `followed` came from the tenant-scoped list_conversations.
    state.followed
    |> Enum.flat_map(fn {conv_id, _runtime} ->
      Conversations._unsafe_list_log_events(conv_id, state.last_id, streams: state.streams)
    end)
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, conn, state.last_id}, fn ev, {:ok, acc, last_id} ->
      case write_event(acc, ev, state) do
        {:ok, c} -> {:cont, {:ok, c, max(ev.id, last_id)}}
        {:error, _} -> {:halt, {:closed, acc, last_id}}
      end
    end)
  end

  defp sse_loop(conn, state) do
    receive do
      {:log_event, %LogEvent{id: ev_id} = ev} when ev_id > state.last_id ->
        if Conversations.event_in_streams?(ev, state.streams) do
          case write_event(conn, ev, state) do
            {:ok, conn} -> sse_loop(conn, %{state | last_id: ev_id})
            {:error, _} -> conn
          end
        else
          sse_loop(conn, %{state | last_id: ev_id})
        end

      {:log_event, _stale} ->
        sse_loop(conn, state)

      {:sidebar_update, _} ->
        # Coalesce the burst: one refollow + one `conversations` event per
        # quiet second, however many pings arrived.
        if state.refollow_pending? do
          sse_loop(conn, state)
        else
          Process.send_after(self(), :refollow, @refollow_debounce_ms)
          sse_loop(conn, %{state | refollow_pending?: true})
        end

      :refollow ->
        followed = follow(state.user_id, state.followed)
        chunk = "event: conversations\ndata: #{Jason.encode!(%{reason: "changed"})}\n\n"

        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> sse_loop(conn, %{state | followed: followed, refollow_pending?: false})
          {:error, _} -> conn
        end

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            sse_loop(conn, state)

          {:error, _} ->
            conn
        end
    after
      idle_timeout_ms() -> conn
    end
  end

  defp write_event(conn, %LogEvent{} = ev, state) do
    runtime = if state.blocks?, do: Map.get(state.followed, ev.conversation_id)

    payload =
      %{
        conversation_id: ev.conversation_id,
        kind: ev.kind,
        stream: ev.stream,
        data: ev.data,
        stage: LogEvent.rendered_stage(ev),
        state: LogEvent.rendered_state(ev),
        duration_ms: ev.duration_ms,
        turn_id: ev.turn_id,
        ts: ev.inserted_at
      }
      |> FountainWeb.ConversationJSON.put_blocks(ev, runtime)
      |> Jason.encode!()

    Plug.Conn.chunk(conn, "id: #{ev.id}\nevent: #{ev.kind}\ndata: #{payload}\n\n")
  end

  defp parse_id(nil), do: 0
  defp parse_id(""), do: 0

  defp parse_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_streams(nil), do: nil
  defp parse_streams(""), do: nil

  defp parse_streams(s) when is_binary(s),
    do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
