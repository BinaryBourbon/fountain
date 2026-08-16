defmodule Fountain.Buzz.Harness do
  @moduledoc """
  A supervised `buzz-acp` process — one per Buzz identity (ADR 0020, Phase 1).

  This GenServer owns the OS process lifecycle and nothing else: it opens
  `buzz-acp` as an Erlang port, watches for its exit, restarts it with a bounded
  backoff, and on shutdown closes the port and runs an `:on_stop` callback (where
  the supervisor revokes the launch's API key). All the tenant-aware work —
  minting the key, decrypting the vault, building the env — happens in
  `Fountain.Buzz.harness_launch/2` *before* this process starts, so the harness
  holds no repo and does no per-tenant query. That split is deliberate: it keeps
  this the one place that reasons about a foreign long-lived binary, and it makes
  the process testable against a fake `buzz-acp` with no database at all.

  `buzz-acp` is the first external OS process the Fountain OTP app manages; the
  restart/backoff and process-group teardown here are the cost of that.

  Start it with the launch spec fields plus lifecycle options:

      Fountain.Buzz.Harness.start_link(
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

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state.port)
    run_on_stop(state.on_stop)
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

  defp close(nil), do: :ok

  # Closing the port EOFs the launcher's held pipe, which TERMs buzz-acp (and,
  # if it will not go, KILLs it) and reaps its `fountain acp` child — see
  # priv/buzz-acp-launch.sh. Without the launcher this only closes the pipe and
  # a bare buzz-acp would be orphaned.
  defp close(port) do
    Port.close(port)
    :ok
  rescue
    # Port already closed between the exit frame and here.
    ArgumentError -> :ok
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
