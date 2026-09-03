defmodule Fountain.Buzz.HarnessTest do
  # async: false — writes fake executables and spawns OS processes.
  use ExUnit.Case, async: false

  alias Fountain.Buzz.Harness

  # The real port middleman, shipped in priv. Every harness spawns through it,
  # so the tests exercise the exact teardown path production uses.
  @launcher Path.expand("../../../priv/buzz-acp-launch.sh", __DIR__)

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

  test "shutdown waits for the launcher OS process to exit", %{dir: dir} do
    launcher =
      write_fake(dir, "slow-launcher", "exec 3<&0\ncat <&3 >/dev/null\nexec sleep 0.2\n")

    cmd = write_fake(dir, "buzz-acp", "exit 0\n")
    pid = start(command: cmd, launcher: launcher, label: "t")
    {:os_pid, launcher_pid} = pid |> :sys.get_state() |> Map.fetch!(:port) |> Port.info(:os_pid)

    :ok = stop_supervised(Harness)

    refute alive?(launcher_pid), "launcher OS process #{launcher_pid} survived shutdown"
  end

  test "surfaces buzz-acp output on the Logger, tagged with the label", %{dir: dir} do
    import ExUnit.CaptureLog

    marker = Path.join(dir, "logged")

    cmd =
      write_fake(
        dir,
        "buzz-acp",
        "echo 'connected to relay'\necho ready > #{marker}\nexec sleep 30\n"
      )

    # Test config filters :info at the primary level; prod logs at :info. Lower
    # the level for this test so the info line is dispatched to the capture.
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)

    log =
      capture_log(fn ->
        pid = start(command: cmd, label: "philo-xyz")
        wait_until(fn -> File.exists?(marker) end)
        _ = :sys.get_state(pid)
        Logger.flush()
      end)

    assert log =~ "[buzz-acp philo-xyz]"
    assert log =~ "connected to relay"
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
    Process.exit(pid, {:name_conflict, {"identity-id", nil}, Fountain.BuzzRegistry, self()})

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
