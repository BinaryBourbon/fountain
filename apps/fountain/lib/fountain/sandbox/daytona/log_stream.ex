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
      conn: nil,
      websocket: nil,
      request_ref: nil,
      upgraded?: false,
      stream: :stdout,
      carry: <<>>,
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
      {:noreply, %{state | conn: conn, request_ref: ref}}
    else
      {:error, reason} -> fail(state, reason)
      {:error, _conn, reason} -> fail(state, reason)
    end
  end

  @impl true
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
          {:halt, acc} -> {:halt, {:done, acc}}
        end
      end)

    case result do
      {:done, state} -> {:stop, :normal, state}
      state -> {:noreply, state}
    end
  end

  defp handle_response({:status, ref, status}, %{request_ref: ref} = state) do
    # A websocket upgrade answers 101 and nothing else.
    if status == 101 do
      {:cont, state}
    else
      {:halt, elem(fail(state, {:upgrade_failed, status}), 2)}
    end
  end

  defp handle_response({:headers, ref, headers}, %{request_ref: ref, upgraded?: false} = state) do
    case Mint.WebSocket.new(state.conn, ref, 101, headers) do
      {:ok, conn, websocket} ->
        {:cont, %{state | conn: conn, websocket: websocket, upgraded?: true}}

      {:error, _conn, reason} ->
        {:halt, elem(fail(state, reason), 2)}
    end
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, upgraded?: true} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)
        if state.exited?, do: {:halt, state}, else: {:cont, state}

      {:error, _websocket, reason} ->
        {:halt, elem(finish_or_fail(state, reason), 2)}
    end
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    {:halt, elem(finish(state), 2)}
  end

  defp handle_response(_response, state), do: {:cont, state}

  defp handle_frame({type, data}, state) when type in [:text, :binary] do
    {segments, stream, carry} = demux(state.carry <> data, state.stream)

    Enum.each(segments, fn {seg_stream, bytes} ->
      send(state.owner, {seg_stream, %{ref: state.ref}, bytes})
    end)

    %{state | stream: stream, carry: carry}
  end

  defp handle_frame({:close, _code, _reason}, state) do
    {:stop, :normal, state} = finish(state)
    state
  end

  defp handle_frame(_frame, state), do: state

  # ── termination ────────────────────────────────────────────────────────────

  # Clean end of stream: the journal is drained and the command exited.
  # The exit code lives on the command record, written just before the
  # daemon closes the stream — poll briefly for the race where the close
  # beats the write.
  defp finish(%{exited?: true} = state), do: {:stop, :normal, state}

  defp finish(state) do
    send(state.owner, {:exit, %{ref: state.ref}, poll_exit_code(state, @exit_poll_attempts)})
    {:stop, :normal, %{state | exited?: true}}
  end

  defp poll_exit_code(_state, 0), do: 0

  defp poll_exit_code(state, attempts) do
    case Toolbox.get_command(state.toolbox_url, state.session_id, state.command_id) do
      {:ok, %{"exitCode" => code}} when is_integer(code) ->
        code

      _ ->
        Process.sleep(@exit_poll_ms)
        poll_exit_code(state, attempts - 1)
    end
  end

  defp finish_or_fail(%{exited?: true} = state, _reason), do: {:stop, :normal, state}

  defp finish_or_fail(state, reason) do
    # The transport dropped. If the command has in fact exited, report the
    # real code; otherwise surface the failure — never a silent exit 0.
    case Toolbox.get_command(state.toolbox_url, state.session_id, state.command_id) do
      {:ok, %{"exitCode" => code}} when is_integer(code) ->
        send(state.owner, {:exit, %{ref: state.ref}, code})

      _ ->
        send(state.owner, {:error, %{ref: state.ref}, reason})
    end

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
