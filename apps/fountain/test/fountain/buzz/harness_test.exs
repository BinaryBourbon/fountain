defmodule Fountain.Buzz.HarnessTest do
  # async: false — writes a fake executable to a tmp dir and spawns OS processes.
  use ExUnit.Case, async: false

  alias Fountain.Buzz.Harness

  # A fake `buzz-acp`: writes its invocation marker to a file (so the test can
  # prove the port opened with the right env) and then behaves as the scenario
  # asks — either sleep forever, or exit after a beat to exercise restart.
  defp write_fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "buzz-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "opens the port with the given env and stays running", %{dir: dir} do
    marker = Path.join(dir, "marker")
    # Record BUZZ_RELAY_URL so we can prove env made it through, then idle.
    cmd = write_fake(dir, "buzz-acp", "printf '%s' \"$BUZZ_RELAY_URL\" > #{marker}\nsleep 30\n")

    pid =
      start_supervised!(
        {Harness, command: cmd, env: [{"BUZZ_RELAY_URL", "wss://relay.example"}], label: "t"}
      )

    assert Harness.running?(pid)
    assert Harness.starts_count(pid) == 1

    wait_until(fn -> File.exists?(marker) end)
    assert File.read!(marker) == "wss://relay.example"
  end

  test "restarts the process when it exits, with backoff", %{dir: dir} do
    counter = Path.join(dir, "count")
    # Append a line each launch, then exit immediately — forces restarts.
    cmd = write_fake(dir, "buzz-acp", "echo x >> #{counter}\nexit 0\n")

    pid =
      start_supervised!({Harness, command: cmd, env: [], restart_backoff_ms: 20, label: "t"})

    # Three launches means at least two restarts happened after the first exit.
    wait_until(fn ->
      File.exists?(counter) and length(File.stream!(counter) |> Enum.to_list()) >= 3
    end)

    assert Harness.starts_count(pid) >= 3
  end

  test "runs the on_stop callback and closes the port on shutdown", %{dir: dir} do
    cmd = write_fake(dir, "buzz-acp", "sleep 30\n")
    test_pid = self()

    pid =
      start_supervised!(
        {Harness, command: cmd, env: [], label: "t", on_stop: fn -> send(test_pid, :stopped) end}
      )

    assert Harness.running?(pid)
    :ok = stop_supervised(Harness)

    assert_receive :stopped, 2_000
  end

  defp wait_until(fun, tries \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
