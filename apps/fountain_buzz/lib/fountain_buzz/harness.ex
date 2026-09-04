defmodule FountainBuzz.Harness do
  @moduledoc """
  A supervised `buzz-acp` process — one per Buzz identity (ADR 0020, Phase 1).

  This GenServer owns the OS process lifecycle and nothing else: it opens
  `buzz-acp` as an Erlang port, watches for its exit, restarts it with a bounded
  backoff, and on shutdown closes the port and runs an `:on_stop` callback (where
  the supervisor revokes the launch's API key). All the tenant-aware work —
  minting the key, decrypting the vault, building the env — happens in
  `FountainBuzz.harness_launch/2` *before* this process starts, so the harness
  holds no repo and does no per-tenant query. That split is deliberate: it keeps
  this the one place that reasons about a foreign long-lived binary, and it makes
  the process testable against a fake `buzz-acp` with no database at all.

  `buzz-acp` is the first external OS process the Fountain OTP app manages; the
  restart/backoff and process-group teardown here are the cost of that.

  Start it with the launch spec fields plus lifecycle options:

      FountainBuzz.Harness.start_link(
        command: launch.command,
        args: launch.args,
        env: launch.env,                 # [{name, value}] — strings
        on_stop: fn -> Buzz.revoke_launch_key(identity, launch.api_key_id) end,
        restart_backoff_ms: 1_000,
        label: identity.id               # for log lines only
      )
  """
  use GenServer

  require Logger

  @default_backoff_ms 1_000
  # priv/buzz-acp-launch.sh TERMs buzz-acp and gives it five seconds before
  # SIGKILL, so six is one second past the worst case the launcher can produce.
  # It has to stay well under the supervisor's `shutdown: 10_000` (manager.ex),
  # which is why `terminate/2` revokes the key before it spends any of this.
  @launcher_shutdown_timeout_ms 6_000
  # Back the poll off rather than firing every 10ms: each check forks a shell,
  # and a node draining its harnesses on a rolling deploy would otherwise spend
  # hundreds of spawns per hung launcher at the worst possible moment. The
  # common case — a launcher already gone — is caught before the first sleep.
  @launcher_poll_start_ms 1
  @launcher_poll_max_ms 50
  # Line-frame buzz-acp's output at the port so a single log line is bounded and
  # a chatty process cannot deliver one unbounded binary.
  @max_line 4_096

  # ── API ────────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "How many times the port has been (re)opened, including the first. For tests/telemetry."
  def starts_count(server), do: GenServer.call(server, :starts_count)

  @doc "Whether a port is currently open."
  def running?(server), do: GenServer.call(server, :running?)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, []),
      # The port middleman that ties buzz-acp's lifetime to the port and reaps it
      # on close (see priv/buzz-acp-launch.sh). Without it, buzz-acp closes its
      # stdio to us, the port reports a false EOF, and we leak a still-live
      # process that stays on the relay. `nil` spawns the command directly (only
      # for callers that do not need teardown — real harnesses always set it).
      launcher: Keyword.get(opts, :launcher),
      shell: Keyword.get(opts, :shell, "/bin/sh"),
      on_stop: Keyword.get(opts, :on_stop),
      backoff_ms: Keyword.get(opts, :restart_backoff_ms, @default_backoff_ms),
      label: Keyword.get(opts, :label, "buzz-acp"),
      port: nil,
      starts: 0
    }

    {:ok, open(state)}
  end

  @impl true
  def handle_call(:starts_count, _from, state), do: {:reply, state.starts, state}

  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("buzz-acp exited: label=#{state.label} status=#{status} — restarting")
    Process.send_after(self(), :reopen, state.backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  # A late message from a port we already replaced or closed. Ignore it.
  def handle_info({_stale_port, {:exit_status, _status}}, state), do: {:noreply, state}

  # buzz-acp's own stdout/stderr (its relay/handshake diagnostics) flow through
  # the launcher to this port. Surface them on the Elixir Logger tagged with the
  # identity, so `kubectl logs` shows why a harness is (or isn't) connected — the
  # thing the first prod smoke could not see. Not log_events: those are
  # conversation-scoped, and a harness is identity-scoped.
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    log_line(state.label, line)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    log_line(state.label, chunk)
    {:noreply, state}
  end

  def handle_info(:reopen, %{port: nil} = state), do: {:noreply, open(state)}

  # Already reopened (a manual restart raced the timer). Nothing to do.
  def handle_info(:reopen, state), do: {:noreply, state}

  # The port process died without an exit_status frame (rare). Treat as an exit.
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    Process.send_after(self(), :reopen, state.backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  # Horde.Registry found two harnesses registered under one identity — two
  # nodes each ran the boot sweep before the cluster formed — and named this
  # one the loser with `Process.exit(pid, {:name_conflict, …})`. Because this
  # process traps exits, that arrives as a message, not a kill; the old
  # catch-all below swallowed it and the loser lived on unregistered, so two
  # `buzz-acp` processes answered the same channel and raced one conversation
  # (`conversation_busy` on every second prompt, 2026-08-17). Stop, so
  # `terminate/2` closes the port, reaps buzz-acp and revokes this launch's key.
  # `{:shutdown, _}` is a clean reason: `:transient` does not restart it.
  def handle_info({:EXIT, _from, {:name_conflict, _key, _registry, winner}}, state) do
    Logger.warning(
      "buzz harness #{state.label}: duplicate of #{inspect(winner)} — stopping this one"
    )

    {:stop, {:shutdown, :name_conflict}, state}
  end

  # Any other linked exit: a :normal one is noise; anything else is a reason
  # to go down through terminate/2 rather than to keep running blind, exactly
  # as ConversationServer treats it. Nothing but the port and the supervisor
  # links to a harness today, so in practice this clause is a backstop.
  def handle_info({:EXIT, _other, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _other, reason}, state), do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # Revoke first, close second. `close/3` can wait seconds on a launcher that is
  # slow to go, and all of this runs under the supervisor's `shutdown: 10_000`:
  # with the wait first, a hung launcher plus a slow database would leave the
  # revoke unfinished at `:brutal_kill` and leak this launch's API key — the one
  # thing `on_stop` exists to prevent. Nothing in `on_stop` needs the OS process
  # to be gone, so the order costs nothing.
  @impl true
  def terminate(_reason, state) do
    run_on_stop(state.on_stop)
    close(state.port, state.launcher, state.shell)
    :ok
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp open(state) do
    {exec, args} = spawn_argv(state)

    port =
      Port.open({:spawn_executable, exec}, [
        :binary,
        :exit_status,
        :hide,
        {:line, @max_line},
        {:args, args},
        {:env, charlist_env(state.env)}
      ])

    %{state | port: port, starts: state.starts + 1}
  end

  defp log_line(_label, ""), do: :ok

  defp log_line(label, line) do
    Logger.info("[buzz-acp #{label}] #{line}")
  end

  # Through the launcher (`/bin/sh <launcher> <command> <args…>`) so buzz-acp is
  # reaped on port close; direct only when no launcher is configured.
  defp spawn_argv(%{launcher: nil} = state), do: {state.command, state.args}

  defp spawn_argv(%{launcher: launcher, shell: shell} = state),
    do: {shell, [launcher, state.command | state.args]}

  defp close(nil, _launcher, _shell), do: :ok

  defp close(port, nil, _shell) do
    close_port(port)
  end

  # Closing the port EOFs the launcher's held pipe, which TERMs buzz-acp (and,
  # if it will not go, KILLs it) and reaps its `fountain acp` child — see
  # priv/buzz-acp-launch.sh. Port.close/1 returns before the launcher OS process
  # necessarily exits, so wait for that process too: callers rely on a completed
  # Harness shutdown meaning its executable and other launch resources are no
  # longer in use (#1469). Without the launcher this only closes the pipe and a
  # bare buzz-acp would be orphaned.
  defp close(port, _launcher, shell) do
    launcher_pid = port_os_pid(port)
    close_port(port)
    await_launcher_exit(launcher_pid, shell)
    :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    # Port already closed between the exit frame and here.
    ArgumentError -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp await_launcher_exit(nil, _shell), do: :ok

  defp await_launcher_exit(os_pid, shell) do
    deadline = System.monotonic_time(:millisecond) + @launcher_shutdown_timeout_ms
    do_await_launcher_exit(os_pid, shell, deadline, @launcher_poll_start_ms)
  end

  defp do_await_launcher_exit(os_pid, shell, deadline, poll_ms) do
    cond do
      not os_process_alive?(os_pid, shell) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("buzz-acp launcher did not exit after shutdown: os_pid=#{os_pid}")

      true ->
        Process.sleep(poll_ms)
        next = min(poll_ms * 2, @launcher_poll_max_ms)
        do_await_launcher_exit(os_pid, shell, deadline, next)
    end
  end

  # `kill -0` through the shell, because it has to be the shell's builtin.
  # `System.cmd/3` resolves an executable with `:os.find_executable/1` and never
  # goes through a shell, and the runtime image — debian:trixie-slim plus
  # libstdc++6, openssl, libncurses6, locales, ca-certificates and tini, see the
  # Dockerfile — ships no /bin/kill, so spawning "kill" directly raises
  # `:enoent` there. The rescue below would read that as "already exited" and
  # skip the wait entirely, in prod only: macOS and the CI runner both have the
  # binary, so every test would still pass. priv/buzz-acp-launch.sh checks the
  # same way for the same reason.
  #
  # sobelow_skip ["CI.System"] — nothing here is reachable by a tenant. `shell`
  # is the harness's own `:shell` option, which no caller sets and which
  # defaults to "/bin/sh"; `os_pid` is an integer from `Port.info/2`, so the
  # interpolation cannot carry a shell metacharacter. The `-c` string is a
  # literal otherwise.
  defp os_process_alive?(os_pid, shell) do
    match?({_, 0}, System.cmd(shell, ["-c", "kill -0 #{os_pid} 2>/dev/null"]))
  rescue
    ErlangError -> false
  end

  defp run_on_stop(nil), do: :ok
  defp run_on_stop(fun) when is_function(fun, 0), do: safe_run(fun)
  defp run_on_stop({m, f, a}), do: safe_run(fn -> apply(m, f, a) end)

  defp safe_run(fun) do
    fun.()
    :ok
  rescue
    e -> Logger.error("buzz-acp on_stop failed: #{inspect(e)}")
  end

  defp charlist_env(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end
end
