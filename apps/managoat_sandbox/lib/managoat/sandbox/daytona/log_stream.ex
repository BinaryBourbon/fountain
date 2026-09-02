defmodule Managoat.Sandbox.Daytona.LogStream do
  @moduledoc """
  Streams a Daytona session command's journaled log into the
  `Managoat.Sandbox` owner-frame contract — by polling the plain HTTP log
  endpoint, deliberately not the websocket.

  The daemon's `?follow=true` websocket was measured live (v0.204.0) to be
  unusable as a transport: it closes the stream almost immediately, replays
  a nondeterministic prefix of the journal on each connect (0, 627, 2042 or
  9207 bytes of a 15692-byte journal, varying per attempt), and never
  serves content the plain GET already returns in full. The GET is
  authoritative and complete, so this process fetches the whole journal on
  a fixed cadence and emits exactly the bytes the owner has not seen —
  `delivered` never resets, which makes the dedupe byte-exact and also
  gives attach its replay-from-start semantics for free (a fresh LogStream
  starts at zero delivered).

  The journal is a single multiplexed byte stream with 3-byte channel
  markers (`0x01 0x01 0x01` → stdout, `0x02 0x02 0x02` → stderr);
  `demux/2` is the pure decoder.

  Command end: the daemon publishes no exit code on command records, so the
  spawn shim writes an exit sentinel file, polled here alongside the
  journal. On exit: one final fetch drains the tail, then the terminal
  frame — exactly one, and never a fabricated exit 0. A sandbox that stops
  answering entirely surfaces `{:error, ...}` after a bounded run of
  consecutive failures.

  Cost note: no Range support server-side, so each poll transfers the full
  journal — O(n²) over a turn's life. Turn output is bounded by the
  conversation byte budget, and typical ACP turns are tens of KB; if a
  provider-side Range ever appears, this is the one place to use it.
  """

  use GenServer

  alias Managoat.Sandbox.Daytona.Toolbox

  require Logger

  @stdout_marker <<1, 1, 1>>
  @stderr_marker <<2, 2, 2>>
  # Fetch cadence — also the output latency ceiling.
  @poll_ms 1_000
  # Consecutive fetch failures tolerated before the stream is declared
  # dead (~30s of an unreachable sandbox).
  @max_consecutive_errors 30

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
      # Total bytes ever delivered to the owner, per stream — never reset.
      delivered: %{stdout: 0, stderr: 0},
      skip: %{stdout: 0, stderr: 0},
      errors: 0,
      exited?: false
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{exited?: true} = state), do: {:stop, :normal, state}

  def handle_info(:poll, state) do
    state = fetch_and_emit(state)

    if state.errors > @max_consecutive_errors do
      send(state.owner, {:error, %{ref: state.ref}, :log_stream_unreachable})
      {:stop, :normal, %{state | exited?: true}}
    else
      case check_exit(state) do
        {:ok, code} ->
          # Final drain: the exit sentinel may have appeared between the
          # fetch above and this check, with output still unfetched.
          state = fetch_and_emit(state)
          send(state.owner, {:exit, %{ref: state.ref}, code})
          {:stop, :normal, %{state | exited?: true}}

        _still_running_or_transient ->
          Process.send_after(self(), :poll, @poll_ms)
          {:noreply, state}
      end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── journal fetch ──────────────────────────────────────────────────────────

  defp fetch_and_emit(state) do
    case Toolbox.get_logs(state.toolbox_url, state.session_id, state.command_id) do
      {:ok, body} when is_binary(body) ->
        emit_journal(state, body)

      {:ok, %{} = body} ->
        # Older daemons answer JSON with per-stream strings.
        state = %{state | skip: state.delivered, errors: 0}
        state = emit_segment({:stdout, body["stdout"] || ""}, state)
        emit_segment({:stderr, body["stderr"] || ""}, state)

      {:error, reason} ->
        if rem(state.errors, 10) == 0 do
          Logger.warning("daytona logstream: journal fetch failed: #{inspect(reason)}")
        end

        %{state | errors: state.errors + 1}
    end
  end

  # Each fetch is the complete journal from byte zero; the cumulative
  # delivered counts are what gets skipped, so every byte reaches the owner
  # exactly once whatever the daemon returned last time.
  defp emit_journal(state, body) do
    {segments, _stream, _carry} = demux(body, :stdout)
    state = %{state | skip: state.delivered, errors: 0}
    Enum.reduce(segments, state, &emit_segment/2)
  end

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

      size == 0 ->
        state

      true ->
        send(state.owner, {stream, %{ref: state.ref}, bytes})
        %{state | delivered: Map.update!(state.delivered, stream, &(&1 + size))}
    end
  end

  # ── exit detection ─────────────────────────────────────────────────────────

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

  # ── demux ──────────────────────────────────────────────────────────────────

  @doc """
  Split a marker-multiplexed chunk into `{stream, bytes}` segments.

  Returns `{segments, current_stream, carry}`; `carry` holds a trailing
  partial marker (a suffix of `0x01 0x01 0x01` / `0x02 0x02 0x02`) that
  must be prepended to the next chunk when decoding incrementally.
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
