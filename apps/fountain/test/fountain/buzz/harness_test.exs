defmodule Fountain.Buzz.HarnessTest do
  # async: false — writes fake executables and spawns OS processes.
  use ExUnit.Case, async: false

  alias Fountain.Buzz.Harness

  # The real port middleman, shipped in priv. Every harness spawns through it,
  # so the tests exercise the exact teardown path production uses.
  @launcher Path.expand("../../../priv/buzz-acp-launch.sh", __DIR__)

  defp write_fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null"]))

  setup do
    assert File.exists?(@launcher), "launcher missing at #{@launcher}"
    dir = Path.join(System.tmp_dir!(), "buzz-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start(opts) do
    start_supervised!({Harness, Keyword.put_new(opts, :launcher, @launcher)})
  end

  test "opens the port with the given env and stays running", %{dir: dir} do
    marker = Path.join(dir, "marker")
    cmd = write_fake(dir, "buzz-acp", "printf '%s' \"$BUZZ_RELAY_URL\" > #{marker}\nsleep 30\n")

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
    cmd = write_fake(dir, "buzz-acp", "exec 0<&- 1>&- 2>&-\nsleep 30\n")

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
    cmd = write_fake(dir, "buzz-acp", "echo $$ > #{pidfile}\nexec 0<&- 1>&- 2>&-\nsleep 300\n")

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

  test "surfaces buzz-acp output on the Logger, tagged with the label", %{dir: dir} do
    import ExUnit.CaptureLog

    cmd = write_fake(dir, "buzz-acp", "echo 'connected to relay'\nsleep 30\n")

    # Test config filters :info at the primary level; prod logs at :info. Lower
    # the level for this test so the info line is dispatched to the capture.
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)

    log =
      capture_log(fn ->
        start(command: cmd, label: "philo-xyz")
        Process.sleep(400)
      end)

    assert log =~ "[buzz-acp philo-xyz]"
    assert log =~ "connected to relay"
  end

  test "runs the on_stop callback on shutdown", %{dir: dir} do
    cmd = write_fake(dir, "buzz-acp", "sleep 30\n")
    test_pid = self()

    start(command: cmd, label: "t", on_stop: fn -> send(test_pid, :stopped) end)
    :ok = stop_supervised(Harness)
    assert_receive :stopped, 2_000
  end

  defp wait_until(fun, tries \\ 200)
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
