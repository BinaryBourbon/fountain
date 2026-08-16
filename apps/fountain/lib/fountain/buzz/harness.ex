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

  def handle_info({port, {:data, _data}}, %{port: port} = state) do
    # buzz-acp writes protocol/diagnostics to its own stdio toward its ACP
    # child, not to us; anything arriving here is noise. Increment 2 wires
    # captured output to log_events — for now, drop it.
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
    port =
      Port.open({:spawn_executable, state.command}, [
        :binary,
        :exit_status,
        :hide,
        {:args, state.args},
        {:env, charlist_env(state.env)}
      ])

    %{state | port: port, starts: state.starts + 1}
  end

  defp close(nil), do: :ok

  # Closing a spawn_executable port terminates its OS process. Reliable teardown
  # of the ACP *child* (`fountain acp` beneath `buzz-acp`) needs a process-group
  # kill, which in turn needs the port spawned in its own session — that arrives
  # with the real binary in increment 2. For now, close the port.
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
