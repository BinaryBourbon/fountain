defmodule Fountain.Runners.FakeDaemon do
  @moduledoc """
  An in-BEAM stand-in for the `fountain runner` daemon, speaking the exact
  wire protocol `Fountain.Runners.Connection` speaks, so the adapter and the
  connection process are exercised end to end without a Go binary or a
  network.

  Two processes:

    * a **socket** process running `Fountain.Runners.Connection` as a
      `WebSock` handler would — it *is* the registered connection process:
      messages from callers reach it as `handle_info/2`, frames from the
      daemon reach it as `handle_in/2`, and pushed frames go to the daemon;
    * the **daemon** process, which implements the ops. Sandboxes are maps
      of files; commands speak the same scripted vocabulary as
      `Fountain.Sandbox.Fake` (`out:`, `err:`, `exit:`, `stay`, `drop`) and
      run as real processes emitting real frames; sessions journal every
      frame and `attach` replays from byte zero.

  `start/2` connects a daemon for `runner_id`; `stop/1` disconnects it (the
  socket process exits, so callers see the disconnected errors). It is the
  executable form of the protocol description in `Connection`'s moduledoc
  and of ADR 0022's wire section — the Go daemon must agree with it.
  """

  alias Fountain.Runners.Connection

  # ── socket runtime ─────────────────────────────────────────────────────────

  defmodule Socket do
    @moduledoc false
    use GenServer

    def start_link(init) do
      GenServer.start_link(__MODULE__, init)
    end

    @impl true
    def init(%{daemon: daemon} = init) do
      case Connection.init(Map.drop(init, [:daemon])) do
        {:ok, state} -> {:ok, %{daemon: daemon, state: state}}
        {:stop, reason, _detail, _state} -> {:stop, reason}
      end
    end

    @impl true
    def handle_info({:daemon_frame, text}, s) do
      Connection.handle_in({text, [opcode: :text]}, s.state) |> after_callback(s)
    end

    def handle_info(msg, s) do
      Connection.handle_info(msg, s.state) |> after_callback(s)
    end

    @impl true
    def terminate(reason, s) do
      Connection.terminate(reason, s.state)
    end

    defp after_callback({:ok, state}, s), do: {:noreply, %{s | state: state}}

    defp after_callback({:push, frames, state}, s) do
      frames
      |> List.wrap()
      |> Enum.each(fn
        {:text, text} -> send(s.daemon, {:socket_frame, IO.iodata_to_binary(text)})
        _control -> :ok
      end)

      {:noreply, %{s | state: state}}
    end

    defp after_callback({:stop, reason, _detail, state}, s),
      do: {:stop, reason, %{s | state: state}}
  end

  # ── daemon ─────────────────────────────────────────────────────────────────

  @doc """
  Connect a fake daemon for the runner. Returns `{:ok, %{socket: pid, daemon: pid}}`.
  The socket process registers in the runner registry, so `Runners.online?/1`
  flips to true.
  """
  def start(runner_id, user_id, opts \\ []) do
    daemon = spawn_link(fn -> daemon_loop(%{sandboxes: %{}, sessions: %{}, socket: nil}) end)

    case Socket.start_link(%{
           runner_id: runner_id,
           user_id: user_id,
           name: Keyword.get(opts, :name, "fake"),
           daemon: daemon
         }) do
      {:ok, socket} ->
        send(daemon, {:socket, socket})
        wait_registered(runner_id, 50)
        {:ok, %{socket: socket, daemon: daemon}}

      {:error, reason} ->
        Process.exit(daemon, :kill)
        {:error, reason}
    end
  end

  @doc """
  Disconnect: the socket process stops through `terminate/2` — as Bandit
  runs a WebSock handler's on close — so the offline broadcast and the
  pending-reply failures fire as they do live; the daemon is killed.
  """
  def stop(%{socket: socket, daemon: daemon}) do
    Process.unlink(socket)
    Process.unlink(daemon)
    ref = Process.monitor(socket)
    if Process.alive?(socket), do: GenServer.stop(socket, :shutdown, 1_000)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      1_000 -> :ok
    end

    Process.exit(daemon, :kill)
    :ok
  end

  defp wait_registered(_runner_id, 0), do: :ok

  defp wait_registered(runner_id, n) do
    if Fountain.Runners.online?(runner_id) do
      :ok
    else
      Process.sleep(10)
      wait_registered(runner_id, n - 1)
    end
  end

  defp daemon_loop(state) do
    receive do
      {:socket, socket} ->
        daemon_loop(%{state | socket: socket})

      {:socket_frame, text} ->
        req = Jason.decode!(text)
        {reply, state} = handle(req, state)
        if reply, do: push(state, Map.put(reply, "id", req["id"]))
        daemon_loop(state)

      {:session_frame, frame} ->
        state = journal(state, frame)
        push(state, frame)
        daemon_loop(state)

      {:after_reply, pid} ->
        send(pid, :go)
        daemon_loop(state)

      {:replay, req_id, frames} ->
        Enum.each(frames, &push(state, Map.put(&1, "replay_for", req_id)))
        daemon_loop(state)

      {:session_done, session_id, code} ->
        state = put_in(state, [:sessions, session_id, :exit], code)
        frame = %{"stream" => "exit", "session_id" => session_id, "code" => code}
        state = journal(state, frame)
        push(state, frame)
        daemon_loop(state)
    end
  end

  defp push(%{socket: socket}, frame) do
    send(socket, {:daemon_frame, Jason.encode!(frame)})
  end

  defp journal(state, %{"session_id" => id} = frame) do
    if Map.has_key?(state.sessions, id) do
      update_in(state, [:sessions, id, :journal], &[frame | &1])
    else
      state
    end
  end

  # ── ops ────────────────────────────────────────────────────────────────────

  defp handle(%{"op" => "create", "name" => name}, state) do
    state =
      update_in(
        state.sandboxes,
        &Map.put_new(&1, name, %{status: "running", files: %{}, path: "/fake/root/" <> name})
      )

    {ok(%{}), state}
  end

  defp handle(%{"op" => "get", "name" => name}, state) do
    with_sandbox(state, name, fn sb ->
      {ok(%{"status" => sb.status, "path" => sb.path}), state}
    end)
  end

  defp handle(%{"op" => "destroy", "name" => name}, state) do
    sessions = for {id, s} <- state.sessions, s.name != name, into: %{}, do: {id, s}
    {ok(%{}), %{state | sandboxes: Map.delete(state.sandboxes, name), sessions: sessions}}
  end

  defp handle(%{"op" => "list"}, state) do
    {ok(%{"names" => Map.keys(state.sandboxes)}), state}
  end

  defp handle(%{"op" => "suspend", "name" => name}, state) do
    with_sandbox(state, name, fn _ ->
      {ok(%{}), put_in(state, [:sandboxes, name, :status], "suspended")}
    end)
  end

  defp handle(%{"op" => "resume", "name" => name}, state) do
    with_sandbox(state, name, fn _ ->
      {ok(%{}), put_in(state, [:sandboxes, name, :status], "running")}
    end)
  end

  defp handle(%{"op" => "write_file", "name" => name, "path" => path, "data" => b64}, state) do
    with_sandbox(state, name, fn _ ->
      {ok(%{}), put_in(state, [:sandboxes, name, :files, path], Base.decode64!(b64))}
    end)
  end

  defp handle(%{"op" => "exec", "name" => name, "args" => args} = req, state) do
    with_sandbox(state, name, fn _ ->
      merge = Map.get(req, "stderr_to_stdout", false)

      {out, code} =
        Enum.reduce(script(args), {[], nil}, fn
          {:stdout, d}, {acc, c} -> {[acc | d], c}
          {:stderr, d}, {acc, c} when merge -> {[acc | d], c}
          {:exit, c}, {acc, nil} -> {acc, c}
          _, acc -> acc
        end)

      out = IO.iodata_to_binary(out)
      {ok(%{"output" => Base.encode64(out), "code" => code || 0}), state}
    end)
  end

  defp handle(%{"op" => "spawn", "name" => name, "cmd" => cmd, "args" => args}, state) do
    with_sandbox(state, name, fn _ ->
      session_id = "s-#{System.unique_integer([:positive])}"
      daemon = self()

      pid =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          run(daemon, session_id, script(args))
        end)

      state =
        put_in(state, [:sessions, session_id], %{
          name: name,
          command: cmd,
          pid: pid,
          exit: nil,
          journal: [],
          created_at: DateTime.utc_now()
        })

      # Reply first, then let the process emit: the connection installs the
      # subscription on the reply, and the daemon never streams before it.
      send(daemon, {:after_reply, pid})
      {ok(%{"session_id" => session_id}), state}
    end)
  end

  defp handle(%{"op" => "stdin", "session_id" => id, "data" => b64}, state) do
    case state.sessions[id] do
      nil ->
        {error("not_found"), state}

      %{exit: code} when not is_nil(code) ->
        {error("command_exited"), state}

      %{pid: pid} ->
        send(pid, {:stdin, Base.decode64!(b64)})
        {ok(%{}), state}
    end
  end

  defp handle(%{"op" => "stdin_close", "session_id" => id}, state) do
    case state.sessions[id] do
      nil ->
        {error("not_found"), state}

      %{pid: pid} ->
        send(pid, :eof)
        {ok(%{}), state}
    end
  end

  defp handle(%{"op" => "detach"}, state), do: {ok(%{}), state}

  defp handle(%{"op" => "list_sessions", "name" => name}, state) do
    with_sandbox(state, name, fn _ ->
      sessions =
        for {id, s} <- state.sessions, s.name == name do
          %{
            "id" => id,
            "command" => s.command,
            "created_at" => DateTime.to_iso8601(s.created_at),
            "tty" => false
          }
        end

      {ok(%{"sessions" => sessions}), state}
    end)
  end

  defp handle(%{"op" => "attach", "session_id" => id, "id" => req_id}, state) do
    case state.sessions[id] do
      nil ->
        {error("not_found"), state}

      session ->
        # Reply first, then replay the journal from byte zero, tagged with this
        # request so only the attacher sees it. The exit frame, if the session
        # already ended, is in the journal too.
        send(self(), {:replay, req_id, Enum.reverse(session.journal)})
        {ok(%{"session_id" => id}), state}
    end
  end

  defp handle(%{"op" => op}, state), do: {error("not_supported", op), state}

  # ── helpers ────────────────────────────────────────────────────────────────

  defp with_sandbox(state, name, fun) do
    case Map.get(state.sandboxes, name) do
      nil -> {error("not_found"), state}
      sb -> fun.(sb)
    end
  end

  defp ok(result), do: %{"ok" => true, "result" => result}
  defp error(code, detail \\ nil), do: %{"ok" => false, "error" => code, "detail" => detail}

  # The scripted vocabulary shared with Fountain.Sandbox.Fake.
  defp script(args) do
    Enum.map(args, fn
      "out:" <> d -> {:stdout, d}
      "err:" <> d -> {:stderr, d}
      "exit:" <> c -> {:exit, String.to_integer(c)}
      "stay" -> :stay
      "drop" -> :drop
    end)
  end

  defp run(daemon, session_id, instructions) do
    Enum.each(instructions, fn
      {:stdout, d} -> emit(daemon, session_id, "stdout", d)
      {:stderr, d} -> emit(daemon, session_id, "stderr", d)
      {:exit, c} -> finish(daemon, session_id, c)
      :drop -> finish(daemon, session_id, 0)
      :stay -> stay(daemon, session_id)
    end)

    unless Enum.any?(instructions, &(&1 in [:stay, :drop] or match?({:exit, _}, &1))) do
      finish(daemon, session_id, 0)
    end
  end

  defp stay(daemon, session_id) do
    receive do
      {:stdin, data} ->
        emit(daemon, session_id, "stdout", "echo:" <> data)
        stay(daemon, session_id)

      :eof ->
        finish(daemon, session_id, 0)
    end
  end

  defp emit(daemon, session_id, stream, data) do
    send(
      daemon,
      {:session_frame,
       %{"stream" => stream, "session_id" => session_id, "data" => Base.encode64(data)}}
    )
  end

  defp finish(daemon, session_id, code) do
    send(daemon, {:session_done, session_id, code})
    exit(:normal)
  end
end
