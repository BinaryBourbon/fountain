defmodule Fountain.Sandbox.Daytona.LogStream do
  @moduledoc """
  Streams a Daytona session command's journaled log over WebSocket and
  translates it into the `Fountain.Sandbox` owner-frame contract.

  The daemon journals every command's output server-side and the log
  endpoint **replays it from byte zero before following** — Daytona
  natively satisfies the replay-from-start contract, so this one process
  serves both live streaming and reattach.

  The wire is a single multiplexed byte stream with 3-byte markers
  switching the current channel: `0x01 0x01 0x01` → stdout,
  `0x02 0x02 0x02` → stderr (`demux/2` is the pure decoder; markers can
  split across WebSocket frames, so up to two trailing marker bytes are
  carried between chunks).

  The daemon closes the stream once the command has exited and the journal
  is drained; the real exit code is then read from the command record
  (`exitCode` is nil while running). A transport-level failure emits an
  `{:error, %{ref: ref}, reason}` frame instead — the command may well
  still be running, which is what reattach exists for.
  """

  use GenServer

  alias Fountain.Sandbox.Daytona.Toolbox

  @stdout_marker <<1, 1, 1>>
  @stderr_marker <<2, 2, 2>>
  @exit_poll_ms 300
  @exit_poll_attempts 10
  # The follow stream can outlive the command (the daemon does not always
  # close it on exit), so liveness comes from polling the command record.
  @exit_watch_ms 2_000

  # Mint.WebSocket.new/4's success depends on connection privates set by
  # upgrade/5 (the websocket key nonce), which dialyzer cannot see through
  # Mint's conn union — it proves the {:ok, conn, websocket} branch
  # unreachable when it is exactly the branch a 101 upgrade takes.
  @dialyzer {:nowarn_function, handle_response: 2}

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      toolbox_url: Keyword.fetch!(opts, :toolbox_url),
      session_id: Keyword.fetch!(opts, :session_id),
      command_id: Keyword.fetch!(opts, :command_id),
      ref: Keyword.fetch!(opts, :ref),
      owner: Keyword.fetch!(opts, :owner),
      # The shim's exit sentinel — the daemon's command record carries no
      # exit code, so this file is the source of truth for command end.
      exit_file: Keyword.get(opts, :exit_file),
      conn: nil,
      websocket: nil,
      request_ref: nil,
      upgraded?: false,
      stream: :stdout,
      carry: <<>>,
      # Total bytes ever delivered to the owner, per stream — never reset.
      # The daemon closes follow streams while commands still run; each
      # reconnect replays the journal from byte zero and skips exactly this
      # many bytes, so the skip is cumulative across any number of drops.
      delivered: %{stdout: 0, stderr: 0},
      skip: %{stdout: 0, stderr: 0},
      reconnects: 0,
      exited?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    url = Toolbox.logs_ws_url(state.toolbox_url, state.session_id, state.command_id)
    uri = URI.parse(url)
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    path = uri.path <> if uri.query, do: "?" <> uri.query, else: ""

    headers = [{"authorization", "Bearer " <> Fountain.Sandbox.Daytona.Api.api_key!()}]

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, headers) do
      Process.send_after(self(), :poll_exit, @exit_watch_ms)
      {:noreply, %{state | conn: conn, request_ref: ref}}
    else
      {:error, reason} -> fail(state, reason)
      {:error, _conn, reason} -> fail(state, reason)
    end
  end

  @impl true
  def handle_info(:poll_exit, %{exited?: true} = state), do: {:stop, :normal, state}

  def handle_info(:poll_exit, state) do
    case check_exit(state) do
      {:ok, code} ->
        drain_and_exit(state, code)

      _still_running_or_transient ->
        Process.send_after(self(), :poll_exit, @exit_watch_ms)
        {:noreply, state}
    end
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_responses(%{state | conn: conn}, responses)

      {:error, _conn, reason, _responses} ->
        finish_or_fail(state, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_responses(state, responses) do
    result =
      Enum.reduce_while(responses, state, fn response, acc ->
        case handle_response(response, acc) do
          {:cont, acc} -> {:cont, acc}
          {:halt, other} -> {:halt, {:done, other}}
        end
      end)

    case result do
      # A finish/reconnect verdict rides through as the gen_server return.
      {:done, {:stop, _, _} = stop} -> stop
      {:done, {:noreply, _, _} = continue} -> continue
      state -> {:noreply, state}
    end
  end

  defp handle_response({:status, ref, status}, %{request_ref: ref} = state) do
    # A websocket upgrade answers 101 and nothing else.
    if status == 101 do
      {:cont, state}
    else
      {:halt, fail(state, {:upgrade_failed, status})}
    end
  end

  defp handle_response({:headers, ref, headers}, %{request_ref: ref, upgraded?: false} = state) do
    case Mint.WebSocket.new(state.conn, ref, 101, headers) do
      {:ok, conn, websocket} ->
        {:cont, %{state | conn: conn, websocket: websocket, upgraded?: true}}

      {:error, _conn, reason} ->
        {:halt, fail(state, reason)}
    end
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, upgraded?: true} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)
        if state.exited?, do: {:halt, {:stop, :normal, state}}, else: {:cont, state}

      {:error, _websocket, reason} ->
        {:halt, finish_or_fail(state, reason)}
    end
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    {:halt, finish(state)}
  end

  defp handle_response(_response, state), do: {:cont, state}

  defp handle_frame({type, data}, state) when type in [:text, :binary] do
    {segments, stream, carry} = demux(state.carry <> data, state.stream)
    state = Enum.reduce(segments, state, &emit_segment/2)
    %{state | stream: stream, carry: carry}
  end

  defp handle_frame({:close, _code, _reason}, state) do
    # The :done (or transport-close) that follows resolves the stream via
    # finish/1; nothing to do at the frame level.
    state
  end

  defp handle_frame(_frame, state), do: state

  # ── segment emission with replay skipping ──────────────────────────────────

  defp emit_segment({stream, bytes}, state) do
    to_skip = state.skip[stream]
    size = byte_size(bytes)

    cond do
      to_skip >= size ->
        %{state | skip: Map.update!(state.skip, stream, &(&1 - size))}

      to_skip > 0 ->
        fresh = binary_part(bytes, to_skip, size - to_skip)
        send(state.owner, {stream, %{ref: state.ref}, fresh})

        %{
          state
          | skip: Map.put(state.skip, stream, 0),
            delivered: Map.update!(state.delivered, stream, &(&1 + byte_size(fresh)))
        }

      true ->
        send(state.owner, {stream, %{ref: state.ref}, bytes})
        %{state | delivered: Map.update!(state.delivered, stream, &(&1 + size))}
    end
  end

  # ── termination and reconnection ───────────────────────────────────────────

  # The stream ended. If the command exited, report its real code; if it is
  # still running — the daemon routinely closes follow streams mid-command —
  # reconnect and skip the bytes already delivered. Never a fabricated
  # exit 0: a close while the command runs is not a verdict.
  defp finish(%{exited?: true} = state), do: {:stop, :normal, state}

  defp finish(state) do
    case poll_exit_code(state, @exit_poll_attempts) do
      {:ok, code} ->
        send(state.owner, {:exit, %{ref: state.ref}, code})
        {:stop, :normal, %{state | exited?: true}}

      :still_running ->
        reconnect(state)
    end
  end

  defp reconnect(state) do
    Process.sleep(min(500 * (state.reconnects + 1), 2_000))

    state = %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        upgraded?: false,
        stream: :stdout,
        carry: <<>>,
        skip: state.delivered,
        reconnects: state.reconnects + 1
    }

    {:noreply, state, {:continue, :connect}}
  end

  defp poll_exit_code(_state, 0), do: :still_running

  defp poll_exit_code(state, attempts) do
    case check_exit(state) do
      {:ok, code} ->
        {:ok, code}

      :still_running ->
        :still_running

      :transient ->
        Process.sleep(@exit_poll_ms)
        poll_exit_code(state, attempts - 1)
    end
  end

  # The command record first (a daemon that publishes exitCode wins), then
  # the shim's sentinel file via a one-shot exec.
  defp check_exit(state) do
    case Toolbox.get_command(state.toolbox_url, state.session_id, state.command_id) do
      {:ok, %{"exitCode" => code}} when is_integer(code) ->
        {:ok, code}

      {:ok, _no_exit_code} ->
        check_exit_file(state)

      {:error, :not_found} ->
        check_exit_file(state)

      {:error, _reason} ->
        :transient
    end
  end

  defp check_exit_file(%{exit_file: nil}), do: :still_running

  defp check_exit_file(state) do
    case Toolbox.execute(state.toolbox_url, "cat #{state.exit_file} 2>/dev/null", timeout: 15_000) do
      {:ok, out, 0} ->
        case Integer.parse(String.trim(out)) do
          {code, _} -> {:ok, code}
          :error -> :still_running
        end

      {:ok, _out, _nonzero} ->
        :still_running

      {:error, _reason} ->
        :transient
    end
  end

  defp finish_or_fail(%{exited?: true} = state, _reason), do: {:stop, :normal, state}

  defp finish_or_fail(state, reason) do
    # The transport dropped. A real exit reports its code; a command still
    # running gets a reconnect; only a command the daemon cannot account for
    # surfaces the transport failure.
    case check_exit(state) do
      {:ok, code} ->
        drain_and_exit(state, code)

      :still_running ->
        reconnect(state)

      :transient ->
        send(state.owner, {:error, %{ref: state.ref}, reason})
        {:stop, :normal, %{state | exited?: true}}
    end
  end

  # The command exited but the follow stream may not have delivered (or may
  # never deliver) the tail. Fetch the full journal, emit whatever the owner
  # has not seen — the cumulative `delivered` skip makes this exact — then
  # deliver the terminal frame.
  defp drain_and_exit(state, code) do
    state =
      case Toolbox.get_logs(state.toolbox_url, state.session_id, state.command_id) do
        {:ok, body} when is_binary(body) ->
          {segments, _stream, _carry} = demux(body, :stdout)
          Enum.reduce(segments, %{state | skip: state.delivered, carry: <<>>}, &emit_segment/2)

        {:ok, %{} = body} ->
          # Older daemons answer JSON with per-stream strings.
          state = %{state | skip: state.delivered}
          state = emit_segment({:stdout, body["stdout"] || ""}, state)
          emit_segment({:stderr, body["stderr"] || ""}, state)

        {:error, _reason} ->
          state
      end

    send(state.owner, {:exit, %{ref: state.ref}, code})
    {:stop, :normal, %{state | exited?: true}}
  end

  defp fail(state, reason) do
    send(state.owner, {:error, %{ref: state.ref}, reason})
    {:stop, :normal, %{state | exited?: true}}
  end

  # ── demux ──────────────────────────────────────────────────────────────────

  @doc """
  Split a marker-multiplexed chunk into `{stream, bytes}` segments.

  Returns `{segments, current_stream, carry}`; `carry` holds a trailing
  partial marker (a suffix of `0x01 0x01 0x01` / `0x02 0x02 0x02`) that
  must be prepended to the next chunk.
  """
  def demux(data, current) do
    do_demux(data, current, <<>>, [])
  end

  defp do_demux(<<>>, current, seg, acc), do: {flush(acc, current, seg), current, <<>>}

  defp do_demux(@stdout_marker <> rest, current, seg, acc),
    do: do_demux(rest, :stdout, <<>>, flush(acc, current, seg))

  defp do_demux(@stderr_marker <> rest, current, seg, acc),
    do: do_demux(rest, :stderr, <<>>, flush(acc, current, seg))

  # A trailing 1 or 2 bytes that could begin a marker: hold them back.
  defp do_demux(rest, current, seg, acc)
       when rest in [<<1>>, <<1, 1>>, <<2>>, <<2, 2>>] do
    {flush(acc, current, seg), current, rest}
  end

  defp do_demux(<<byte, rest::binary>>, current, seg, acc),
    do: do_demux(rest, current, seg <> <<byte>>, acc)

  defp flush(acc, _stream, <<>>), do: acc
  defp flush(acc, stream, seg), do: acc ++ [{stream, seg}]
end
