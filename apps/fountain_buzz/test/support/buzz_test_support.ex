defmodule FountainBuzz.TestSupport do
  @moduledoc false

  @doc """
  A stand-in `buzz-acp` that blocks, and answers `--version` with the pin.

  `FountainBuzz.Assets.compatible?/0` refuses a binary whose version does not
  match `apps/fountain_buzz/buzz-acp.version` (#1509), so a fake that cannot
  answer would make every harness test exercise the refusal path rather than
  the thing it is about. Reporting the pin is what makes it a stand-in and not
  merely an executable file.
  """
  def write_fake_acp!(path) do
    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "buzz-acp #{FountainBuzz.Assets.pinned_version()}"; exit 0; fi
    exec sleep 30
    """)

    File.chmod!(path, 0o755)
    path
  end

  alias FountainBuzz.Manager

  @supervisor FountainBuzz.Supervisor
  @drain_tries 500

  # Horde reports a child as :restarting between the old PID going down and
  # start_harness_link/2 returning its replacement. A one-shot PID snapshot
  # skips that entry and lets its next database query outlive the test's SQL
  # sandbox owner (#1351). Keep draining while the owner is still alive.
  def stop_all_harnesses!(tries \\ @drain_tries)

  def stop_all_harnesses!(0) do
    raise """
    BuzzSupervisor still has children after test teardown: \
    #{inspect(Horde.DynamicSupervisor.which_children(@supervisor))}

    This supervisor is global, so the children are not necessarily this test's.
    Every module that starts one is async: false today, which is what makes the
    check safe to fail on; if that changes, scope the drain before relaxing it.
    """
  end

  def stop_all_harnesses!(tries) do
    @supervisor
    |> Horde.DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) ->
        _ = Horde.DynamicSupervisor.terminate_child(@supervisor, pid)

      {_, :restarting, _, _} ->
        :ok

      # Horde is free to grow the child tuple. A FunctionClauseError raised here
      # would come out of on_exit and fail an unrelated test with the wrong
      # story, so take the next loop rather than the exception.
      _other ->
        :ok
    end)

    case Horde.DynamicSupervisor.which_children(@supervisor) do
      [] ->
        await_registry_drained!(tries)

      _children ->
        Process.sleep(10)
        stop_all_harnesses!(tries - 1)
    end
  end

  # An empty supervisor is not the whole drain. The registry learns of an exit
  # **by monitor**, so it keeps counting a harness for a moment after
  # `terminate_child/2` has returned — `Manager.await_stopped/2` documents the
  # same lag, and #1544 is what it looks like inside one test.
  #
  # Across modules it looks like #1533 instead: teardown returns, the next
  # module reads `running_count/0` as its baseline, and the entry this drain
  # already killed disappears afterwards, moving the count under a test that
  # took the number as fixed. So teardown means "nothing is registered", not
  # "nothing is supervised".
  defp await_registry_drained!(0) do
    raise """
    BuzzRegistry still counts #{Manager.running_count()} harness(es) after \
    BuzzSupervisor drained.

    The supervisor is empty, so these are registry entries for processes that \
    are already down, and something is stopping Horde from reaping them. \
    Leaving them would hand the next module a `running_count/0` baseline that \
    changes under it (#1533).
    """
  end

  defp await_registry_drained!(tries) do
    if Manager.running_count() == 0 do
      :ok
    else
      Process.sleep(10)
      await_registry_drained!(tries - 1)
    end
  end
end
