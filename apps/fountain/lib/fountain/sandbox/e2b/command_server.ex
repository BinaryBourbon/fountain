defmodule Fountain.Sandbox.E2B.CommandServer do
  @moduledoc """
  One process per streaming E2B command: owns the Connect stream, translates
  envd events into the `Fountain.Sandbox` owner-frame contract, and
  heartbeats the sandbox TTL while the command lives.

  E2B sandboxes always carry a TTL, so a long agent turn must keep extending
  it — a missed heartbeat degrades to an auto-pause (state preserved), never
  a kill, because the adapter creates sandboxes with `autoPause: true`.

  Frame mapping (envd `StartResponse`/`ConnectResponse` events, JSON codec):

    * `data.stdout` / `data.stderr` (base64) → `{:stdout | :stderr, %{ref: ref}, bin}`
    * `end.exitCode` → `{:exit, %{ref: ref}, code}`
    * EndStream (flag 2) with an error → `{:error, %{ref: ref}, reason}`
    * EndStream without a preceding end event → `{:exit, %{ref: ref}, 0}` —
      the server finished the stream deliberately; per the contract a close
      without an exit frame reads as success
    * transport failure → `{:error, %{ref: ref}, reason}` — the process may
      still be running sandbox-side; reattach exists for exactly this

  In `:attach` mode the stream is a `tail`-based replayer over the journal
  files the spawn shim wrote (see `Fountain.Sandbox.E2B`), so the buffered
  output replays from byte zero; the real exit code is read from the shim's
  exit file when the replayer ends.
  """

  use GenServer

  alias Fountain.Sandbox.E2B.Api
  alias Fountain.Sandbox.E2B.Envd

  require Logger

  @heartbeat_ms 240_000

  def start(opts), do: GenServer.start(__MODULE__, opts)

  def write_stdin(pid, data), do: GenServer.call(pid, {:write_stdin, data})
  def close_stdin(pid), do: GenServer.call(pid, :close_stdin)

  @impl true
  def init(opts) do
    state = %{
      sandbox_id: Keyword.fetch!(opts, :sandbox_id),
      tag: Keyword.fetch!(opts, :tag),
      ref: Keyword.fetch!(opts, :ref),
      owner: Keyword.fetch!(opts, :owner),
      # In attach mode, stdin targets the ORIGINAL tagged process while the
      # stream comes from the replayer.
      stdin_tag: Keyword.get(opts, :stdin_tag, Keyword.fetch!(opts, :tag)),
      request: Keyword.fetch!(opts, :request),
      exit_file: Keyword.get(opts, :exit_file),
      buffer: <<>>,
      exited?: false,
      heartbeat: nil,
      stream_task: nil
    }

    {:ok, state, {:continue, :open_stream}}
  end

  @impl true
  def handle_continue(:open_stream, state) do
    server = self()
    %{sandbox_id: sandbox_id, request: {path, payload}} = state

    task =
      Task.async(fn ->
        Req.post(Envd.req(sandbox_id),
          url: "/" <> path,
          headers: [{"content-type", Envd.stream_content_type()}],
          body: Envd.encode_frame(payload),
          receive_timeout: :infinity,
          into: fn {:data, data}, {req, resp} ->
            send(server, {:chunk, data})
            {:cont, {req, resp}}
          end
        )
      end)

    heartbeat = :timer.send_interval(@heartbeat_ms, :heartbeat)
    {:noreply, %{state | stream_task: task, heartbeat: heartbeat}}
  end

  @impl true
  def handle_call({:write_stdin, data}, _from, state) do
    {:reply, Envd.send_input(state.sandbox_id, state.stdin_tag, data), state}
  end

  def handle_call(:close_stdin, _from, state) do
    {:reply, Envd.close_stdin(state.sandbox_id, state.stdin_tag), state}
  end

  @impl true
  def handle_info({:chunk, data}, state) do
    {frames, rest} = Envd.decode_frames(state.buffer <> data)
    state = Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)

    if state.exited? do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state) do
    case Api.set_timeout(state.sandbox_id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("e2b: TTL heartbeat failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({ref, result}, %{stream_task: %Task{ref: ref}} = state) do
    # The HTTP request finished. If no terminal frame was delivered yet, this
    # is where the close-without-exit and transport-failure verdicts land.
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, _resp} -> finish(state, {:exit, 0})
        {:error, reason} -> finish(state, {:error, reason})
      end

    {:stop, :normal, %{state | stream_task: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    state = finish(state, {:error, {:stream_task_down, reason}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.heartbeat, do: :timer.cancel(state.heartbeat)
    if state.stream_task, do: Task.shutdown(state.stream_task, :brutal_kill)
    :ok
  end

  # ── frame handling ─────────────────────────────────────────────────────────

  defp handle_frame({:message, %{"event" => event}}, state), do: handle_event(event, state)
  defp handle_frame({:message, _other}, state), do: state

  defp handle_frame({:end_stream, trailers}, state) do
    case trailers do
      %{"error" => error} when not is_nil(error) -> finish(state, {:error, error})
      _ -> finish(state, {:exit, 0})
    end
  end

  defp handle_event(%{"data" => data}, state) do
    emit_data(state, :stdout, data["stdout"])
    emit_data(state, :stderr, data["stderr"])
    state
  end

  defp handle_event(%{"end" => end_event}, state) do
    finish(state, {:exit, end_event["exitCode"] || 0})
  end

  defp handle_event(_other, state), do: state

  defp emit_data(_state, _stream, nil), do: :ok

  defp emit_data(state, stream, base64) do
    case Base.decode64(base64) do
      {:ok, ""} -> :ok
      {:ok, bin} -> send(state.owner, {stream, %{ref: state.ref}, bin})
      :error -> :ok
    end
  end

  # Exactly one terminal frame, ever. In attach mode the replayer's own clean
  # exit is a proxy — the real code comes from the shim's exit file.
  defp finish(%{exited?: true} = state, _terminal), do: state

  defp finish(state, {:exit, code}) do
    code = if state.exit_file, do: read_exit_code(state, code), else: code
    send(state.owner, {:exit, %{ref: state.ref}, code})
    %{state | exited?: true}
  end

  defp finish(state, {:error, reason}) do
    send(state.owner, {:error, %{ref: state.ref}, reason})
    %{state | exited?: true}
  end

  defp read_exit_code(state, fallback) do
    case Envd.read_file(state.sandbox_id, state.exit_file) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {code, _} -> code
          :error -> fallback
        end

      {:error, _} ->
        fallback
    end
  end
end
