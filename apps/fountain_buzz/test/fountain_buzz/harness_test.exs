defmodule FountainBuzz.HarnessTest.LogSink do
  @moduledoc false
  # A :logger handler that forwards every event to a test process. :logger calls
  # `log/2` in the process that logged, so receiving the message is proof the
  # harness reached the Logger — the ordering a marker file cannot give.

  def log(%{msg: msg}, %{config: %{pid: pid}}) do
    send(pid, {:log_line, flatten(msg)})
    :ok
  end

  defp flatten({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp flatten({:report, report}), do: inspect(report)

  defp flatten({format, args}) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end
end

defmodule FountainBuzz.HarnessTest do
  # async: false — writes fake executables and spawns OS processes.
  use ExUnit.Case, async: false

  alias FountainBuzz.Harness

  # The real port middleman, shipped in priv. Every harness spawns through it,
  # so the tests exercise the exact teardown path production uses.
  @launcher Path.expand("../../priv/buzz-acp-launch.sh", __DIR__)

  # A fake that blocks must `exec` its last command, never background it behind
  # the shell. The launcher TERMs the pid this script reports, which is the
  # shell's; a plain `sleep 300` is the shell's *child* and `sh` does not
  # forward the signal, so it orphans onto init still holding the stdio it
  # inherited from the BEAM. `mix test | tee` (scripts/test-partition.sh) then
  # cannot see EOF until that sleep expires — five silent minutes on the CI
  # critical path, with every assertion green, because the pid the test watches
  # really did die. `exec` makes the reported pid the process that blocks.
  defp write_fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null"]))

  setup do
    assert File.exists?(@launcher), "launcher missing at #{@launcher}"
    %{dir: Fountain.TmpDir.mkdir!("buzz-harness")}
  end

  defp start(opts) do
    start_supervised!({Harness, Keyword.put_new(opts, :launcher, @launcher)})
  end

  test "opens the port with the given env and stays running", %{dir: dir} do
    marker = Path.join(dir, "marker")

    cmd =
      write_fake(dir, "buzz-acp", "printf '%s' \"$BUZZ_RELAY_URL\" > #{marker}\nexec sleep 30\n")

    pid = start(command: cmd, env: [{"BUZZ_RELAY_URL", "wss://relay.example"}], label: "t")

    assert Harness.running?(pid)
    assert Harness.starts_count(pid) == 1
    wait_until(fn -> File.exists?(marker) end)
    assert File.read!(marker) == "wss://relay.example"
  end

  test "restarts the process when it really exits, with backoff", %{dir: dir} do
    counter = Path.join(dir, "count")
    cmd = write_fake(dir, "buzz-acp", "echo x >> #{counter}\nexit 0\n")

    pid = start(command: cmd, restart_backoff_ms: 20, label: "t")

    wait_until(fn ->
      File.exists?(counter) and length(File.stream!(counter) |> Enum.to_list()) >= 3
    end)

    assert Harness.starts_count(pid) >= 3
  end

  # The bug this whole change exists to fix (#736): buzz-acp closes its stdio to
  # the BEAM, which a bare port reads as a false exit and restarts — leaking a
  # still-live process. Through the launcher the port stays open, so no restart.
  test "does NOT restart when the child merely closes its stdio", %{dir: dir} do
    # Close stdin/stdout/stderr toward the port, then keep running.
    cmd = write_fake(dir, "buzz-acp", "exec 0<&- 1>&- 2>&-\nexec sleep 30\n")

    pid = start(command: cmd, restart_backoff_ms: 20, label: "t")

    Process.sleep(700)
    assert Harness.running?(pid)
    assert Harness.starts_count(pid) == 1, "the harness restarted a still-live child"
  end

  # The other half of the fix: on shutdown the OS process must actually die, not
  # orphan onto the relay. The fake closes its stdio (like the real one) so only
  # the launcher's teardown can reap it.
  test "reaps the child OS process on shutdown", %{dir: dir} do
    pidfile = Path.join(dir, "childpid")

    cmd =
      write_fake(dir, "buzz-acp", "echo $$ > #{pidfile}\nexec 0<&- 1>&- 2>&-\nexec sleep 300\n")

    start(command: cmd, label: "t")
    wait_until(fn -> File.exists?(pidfile) end)
    child = File.read!(pidfile) |> String.trim() |> String.to_integer()
    assert alive?(child)

    :ok = stop_supervised(Harness)

    reaped =
      Enum.reduce_while(1..80, false, fn _, _ ->
        Process.sleep(100)
        if alive?(child), do: {:cont, false}, else: {:halt, true}
      end)

    assert reaped, "child OS process #{child} survived shutdown (leaked)"
  end

  # Under a PATH with no `kill` on it, which is what the runtime image is: it is
  # debian:trixie-slim plus six packages (Dockerfile), and none of them ship
  # /bin/kill — `kill` there is only the shell's builtin. `System.cmd/3`
  # resolves an executable with `:os.find_executable/1` and never through a
  # shell, so a liveness probe that spawns "kill" raises :enoent in production,
  # gets read as "the launcher already exited", and skips this wait — while
  # passing on macOS and the CI runner, which both have the binary. Restricting
  # PATH is how that image is reachable from here. `cat` and `sleep` are on it
  # because the fake launcher below needs them, and `sh` because `alive?/1`
  # does; `kill` is left off deliberately.
  test "shutdown waits for the launcher OS process to exit, with no `kill` on PATH",
       %{dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for tool <- ~w(sh cat sleep) do
      File.ln_s!(System.find_executable(tool), Path.join(bin, tool))
    end

    refute File.exists?(Path.join(bin, "kill")), "the point of this test is that kill is absent"

    launcher =
      write_fake(dir, "slow-launcher", "exec 3<&0\ncat <&3 >/dev/null\nexec sleep 0.2\n")

    cmd = write_fake(dir, "buzz-acp", "exit 0\n")
    pid = start(command: cmd, launcher: launcher, label: "t")
    {:os_pid, launcher_pid} = pid |> :sys.get_state() |> Map.fetch!(:port) |> Port.info(:os_pid)

    prev_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", prev_path) end)
    System.put_env("PATH", bin)

    try do
      :ok = stop_supervised(Harness)
    after
      System.put_env("PATH", prev_path)
    end

    refute alive?(launcher_pid), "launcher OS process #{launcher_pid} survived shutdown"
  end

  test "surfaces buzz-acp output on the Logger, tagged with the label", %{dir: dir} do
    import ExUnit.CaptureLog

    cmd = write_fake(dir, "buzz-acp", "echo 'connected to relay'\nexec sleep 30\n")

    # Test config filters :info at the primary level; prod logs at :info. Lower
    # the level for this test so the info line is dispatched at all.
    prev = Logger.level()
    Logger.configure(level: :info)

    # Wait on the log event itself, not on a side effect of the fake. The fake's
    # `echo` returning only proves its write(2) into the pipe returned; the
    # emulator's port reader then delivers {:data, {:eol, _}} to the harness
    # asynchronously, and nothing orders that against this process. A marker
    # file races exactly the same way the 400ms sleep this replaced did, only
    # faster, and `:sys.get_state/1` flushes a mailbox the line may not have
    # reached yet (#1469).
    handler = :"harness_log_#{System.unique_integer([:positive])}"
    sink = FountainBuzz.HarnessTest.LogSink
    :ok = :logger.add_handler(handler, sink, %{level: :info, config: %{pid: self()}})

    on_exit(fn ->
      _ = :logger.remove_handler(handler)
      Logger.configure(level: prev)
    end)

    # capture_log only to keep the line out of the test output; the assertion is
    # on what the handler delivered.
    capture_log(fn ->
      start(command: cmd, label: "philo-xyz")
      assert await_log_line("[buzz-acp philo-xyz]") =~ "connected to relay"
    end)
  end

  # The harness logs its own lines too, so take the first *match* rather than the
  # first message. On a deadline, so a stream of non-matching lines cannot keep
  # extending the wait.
  defp await_log_line(substring, timeout \\ 5_000) do
    do_await_log_line(substring, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_await_log_line(substring, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {:log_line, line} ->
        if String.contains?(line, substring),
          do: line,
          else: do_await_log_line(substring, deadline)
    after
      max(left, 0) -> flunk("no log line containing #{inspect(substring)}")
    end
  end

  # 2026-08-17: two pods ran the boot sweep before the cluster formed, both
  # registered a harness for FizzTheShark, and the Horde loser ignored the
  # name-conflict exit — two buzz-acp processes answered one channel.
  test "a Horde name-conflict exit stops the loser: port reaped, on_stop run", %{dir: dir} do
    pidfile = Path.join(dir, "childpid")
    cmd = write_fake(dir, "buzz-acp", "echo $$ > #{pidfile}\nexec sleep 300\n")
    test_pid = self()

    pid = start(command: cmd, label: "t", on_stop: fn -> send(test_pid, :stopped) end)
    wait_until(fn -> File.exists?(pidfile) end)
    child = File.read!(pidfile) |> String.trim() |> String.to_integer()
    ref = Process.monitor(pid)

    # What Horde.Registry sends the losing process (registry_impl.ex).
    Process.exit(pid, {:name_conflict, {"identity-id", nil}, FountainBuzz.Registry, self()})

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :name_conflict}}, 2_000
    assert_receive :stopped, 2_000

    reaped =
      Enum.reduce_while(1..80, false, fn _, _ ->
        Process.sleep(100)
        if alive?(child), do: {:cont, false}, else: {:halt, true}
      end)

    assert reaped, "the loser's buzz-acp #{child} survived (leaked)"
  end

  test "a :normal linked exit is ignored — the harness keeps running", %{dir: dir} do
    cmd = write_fake(dir, "buzz-acp", "exec sleep 30\n")
    pid = start(command: cmd, label: "t")
    # What a linked helper that exits normally would deliver to a trapping process.
    send(pid, {:EXIT, self(), :normal})
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "runs the on_stop callback on shutdown", %{dir: dir} do
    cmd = write_fake(dir, "buzz-acp", "exec sleep 30\n")
    test_pid = self()

    start(command: cmd, label: "t", on_stop: fn -> send(test_pid, :stopped) end)
    :ok = stop_supervised(Harness)
    assert_receive :stopped, 2_000
  end

  defp wait_until(fun, tries \\ 1_000)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_until(fun, tries - 1)
        )
  end
end
