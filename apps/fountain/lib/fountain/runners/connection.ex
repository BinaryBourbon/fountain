defmodule Fountain.Runners.Connection do
  @moduledoc """
  The server end of one `fountain runner` socket (ADR 0022).

  A `WebSock` handler: it registers itself in `Fountain.RunnerRegistry` under
  the runner's id, turns `call/3` requests from anywhere in the cluster into
  JSON frames, matches the daemon's replies back to the callers, and forwards
  the daemon's unsolicited `stream` frames to the owner of the command they
  belong to as the standard `Fountain.Sandbox` owner messages.

  ## Wire protocol

  Text frames, JSON objects. Fountain → daemon, one request per `id`:

      {"id": 7, "op": "spawn", "name": "runner-…", "cmd": "…", "args": [...], ...}

  Daemon → Fountain, one reply per request plus unsolicited stream frames:

      {"id": 7, "ok": true,  "result": {...}}
      {"id": 7, "ok": false, "error": "not_found", "detail": "…"}
      {"stream": "stdout" | "stderr", "session_id": "s-…", "data": "<base64>"}
      {"stream": "exit",  "session_id": "s-…", "code": 0}
      {"stream": "stdout", "session_id": "s-…", "data": "…", "replay_for": 7}

  A `spawn`/`attach` request names the owner and ref its session's frames
  should reach; the subscription is installed *before* the reply is delivered
  so no frame can slip past it. The daemon sends the reply first, then replays
  the session's journal from byte zero tagged `replay_for` with that request's
  id — those frames reach only the subscriber that request installed, so a
  second attacher's replay never duplicates output at the first owner — and
  then streams live frames, which reach every subscriber of the session.

  ## Failure

  When the socket closes, every caller still waiting gets
  `{:error, {:unavailable, :runner_disconnected}}` and every subscribed owner
  gets `{:error, %{ref: ref}, :runner_disconnected}` — a transport failure in
  the contract's terms, after which no `:exit` follows. Detached sessions on
  the daemon keep running; that is what reattach is for.
  """

  @behaviour WebSock

  alias Fountain.Runners

  require Logger

  @heartbeat_ms 20_000
  @default_timeout 30_000

  # ── caller API ─────────────────────────────────────────────────────────────

  @doc """
  Send a request to the runner and wait for its reply.

  Options: `:timeout` (ms or `:infinity`, default #{@default_timeout});
  `:subscribe` — `{owner_pid, ref}` for `spawn`/`attach`, installed on the
  session id the reply names before the reply is returned.

  Returns `{:ok, result}` / `{:error, reason}` with the daemon's error string
  already normalized into the sandbox error taxonomy, or
  `{:error, {:unavailable, :runner_offline | :runner_disconnected | :runner_timeout}}`.
  """
  @spec call(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(runner_id, %{} = payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Runners.whereis(runner_id) do
      nil ->
        {:error, {:unavailable, :runner_offline}}

      pid ->
        ref = Process.monitor(pid)
        send(pid, {:rpc, self(), ref, payload, Keyword.get(opts, :subscribe)})

        receive do
          {:runner_reply, ^ref, result} ->
            Process.demonitor(ref, [:flush])
            result

          {:DOWN, ^ref, :process, _pid, _reason} ->
            {:error, {:unavailable, :runner_disconnected}}
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            {:error, {:unavailable, :runner_timeout}}
        end
    end
  end

  @doc "Stop forwarding a session's frames to `ref`'s owner (this end only)."
  @spec unsubscribe(binary(), String.t(), reference()) :: :ok
  def unsubscribe(runner_id, session_id, ref) do
    case Runners.whereis(runner_id) do
      nil -> :ok
      pid -> send(pid, {:unsubscribe, session_id, ref})
    end

    :ok
  end

  # ── WebSock ────────────────────────────────────────────────────────────────

  @impl WebSock
  def init(%{runner_id: runner_id, user_id: user_id} = init) do
    case Horde.Registry.register(Runners.registry(), {:runner, runner_id}, %{user_id: user_id}) do
      {:ok, _} ->
        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        Logger.info("runner #{init[:name]} (#{runner_id}) connected for user #{user_id}")

        {:ok,
         %{
           runner_id: runner_id,
           user_id: user_id,
           name: init[:name],
           next_id: 1,
           pending: %{},
           subs: %{},
           owners: %{}
         }}

      {:error, {:already_registered, _pid}} ->
        {:stop, :normal, {4409, "a runner named #{init[:name]} is already connected"},
         %{runner_id: runner_id, pending: %{}, subs: %{}, owners: %{}}}
    end
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"id" => id} = reply} when is_integer(id) ->
        {:ok, handle_reply(id, reply, state)}

      {:ok, %{"stream" => stream, "session_id" => session_id} = frame} ->
        {:ok, handle_stream(stream, session_id, frame, state)}

      {:ok, other} ->
        Logger.warning("runner #{state.runner_id}: unexpected frame #{inspect(other)}")
        {:ok, state}

      {:error, _} ->
        {:stop, :normal, {1003, "frames must be JSON text"}, state}
    end
  end

  def handle_in({_binary, [opcode: :binary]}, state) do
    {:stop, :normal, {1003, "frames must be JSON text"}, state}
  end

  @impl WebSock
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:rpc, from, ref, payload, subscribe}, state) do
    id = state.next_id
    frame = payload |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("id", id)

    state = %{
      state
      | next_id: id + 1,
        pending: Map.put(state.pending, id, {from, ref, subscribe})
    }

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:unsubscribe, session_id, ref}, state) do
    state = drop_sub(state, session_id, ref)

    # The daemon has one attached bit per session; it flips off only when the
    # last listener here is gone, so a second subscriber is not silenced by
    # the first one leaving.
    if Map.has_key?(state.subs, session_id) do
      {:ok, state}
    else
      {:push, {:text, Jason.encode!(%{"id" => 0, "op" => "detach", "session_id" => session_id})},
       state}
    end
  end

  def handle_info(:heartbeat, state) do
    Runners.touch(state.runner_id)
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:push, {:ping, ""}, state}
  end

  def handle_info({:runner_deleted, _id}, state) do
    {:stop, :normal, {4404, "runner deleted"}, state}
  end

  def handle_info({:DOWN, _mref, :process, pid, _reason}, state) do
    # An owner (a ConversationServer, a test) went away: forget its
    # subscriptions and tell the daemon nobody is listening to those sessions.
    {gone, subs} =
      Enum.reduce(state.subs, {[], %{}}, fn {session_id, list}, {gone, acc} ->
        case Enum.reject(list, fn {owner, _ref, _req_id} -> owner == pid end) do
          [] -> {[session_id | gone], acc}
          rest -> {gone, Map.put(acc, session_id, rest)}
        end
      end)

    frames =
      Enum.map(gone, fn session_id ->
        {:text, Jason.encode!(%{"id" => 0, "op" => "detach", "session_id" => session_id})}
      end)

    state = %{state | subs: subs, owners: Map.delete(state.owners, pid)}

    case frames do
      [] -> {:ok, state}
      frames -> {:push, frames, state}
    end
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("runner #{state[:name]} (#{state.runner_id}) disconnected: #{inspect(reason)}")

    Enum.each(state.pending, fn {_id, {from, ref, _sub}} ->
      send(from, {:runner_reply, ref, {:error, {:unavailable, :runner_disconnected}}})
    end)

    Enum.each(state.subs, fn {_session_id, list} ->
      Enum.each(list, fn {owner, ref, _req_id} ->
        send(owner, {:error, %{ref: ref}, :runner_disconnected})
      end)
    end)

    :ok
  end

  # ── replies ────────────────────────────────────────────────────────────────

  defp handle_reply(id, reply, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, ref, subscribe}, pending} ->
        state = %{state | pending: pending}
        result = decode_result(reply)

        state =
          case {result, subscribe} do
            {{:ok, %{"session_id" => session_id}}, {owner, cmd_ref}} ->
              add_sub(state, session_id, owner, cmd_ref, id)

            _ ->
              state
          end

        send(from, {:runner_reply, ref, result})
        state
    end
  end

  defp decode_result(%{"ok" => true} = reply), do: {:ok, Map.get(reply, "result", %{})}

  defp decode_result(%{"ok" => false} = reply) do
    {:error, normalize_error(Map.get(reply, "error"), Map.get(reply, "detail"))}
  end

  defp decode_result(reply), do: {:error, {:provider, :runner, {:malformed_reply, reply}}}

  @doc false
  def normalize_error("not_found", _), do: :not_found
  def normalize_error("command_exited", _), do: :command_exited
  def normalize_error("not_supported", _), do: :not_supported
  def normalize_error("invalid", detail), do: {:invalid, detail}
  def normalize_error("unavailable", detail), do: {:unavailable, detail}
  def normalize_error("write_failed", detail), do: {:write_failed, detail}
  def normalize_error(other, detail), do: {:provider, :runner, {other, detail}}

  # ── streams ────────────────────────────────────────────────────────────────

  defp handle_stream(stream, session_id, frame, state) do
    subs =
      case Map.get(frame, "replay_for") do
        nil -> Map.get(state.subs, session_id, [])
        req_id -> state.subs |> Map.get(session_id, []) |> Enum.filter(&(elem(&1, 2) == req_id))
      end

    case stream do
      "stdout" -> deliver(subs, fn ref -> {:stdout, %{ref: ref}, data(frame)} end)
      "stderr" -> deliver(subs, fn ref -> {:stderr, %{ref: ref}, data(frame)} end)
      "exit" -> deliver(subs, fn ref -> {:exit, %{ref: ref}, Map.get(frame, "code", 0)} end)
      _ -> :ok
    end

    if stream == "exit", do: drop_session(state, session_id), else: state
  end

  defp deliver(subs, build) do
    Enum.each(subs, fn {owner, ref, _req_id} -> send(owner, build.(ref)) end)
  end

  defp data(%{"data" => b64}) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> b64
    end
  end

  defp data(_), do: ""

  defp add_sub(state, session_id, owner, ref, req_id) do
    owners =
      if Map.has_key?(state.owners, owner),
        do: state.owners,
        else: Map.put(state.owners, owner, Process.monitor(owner))

    entry = {owner, ref, req_id}

    %{
      state
      | subs: Map.update(state.subs, session_id, [entry], &[entry | &1]),
        owners: owners
    }
  end

  defp drop_sub(state, session_id, ref) do
    case Map.get(state.subs, session_id) do
      nil ->
        state

      list ->
        case Enum.reject(list, fn {_owner, r, _req_id} -> r == ref end) do
          [] -> %{state | subs: Map.delete(state.subs, session_id)}
          rest -> %{state | subs: Map.put(state.subs, session_id, rest)}
        end
    end
  end

  defp drop_session(state, session_id) do
    %{state | subs: Map.delete(state.subs, session_id)}
  end
end
