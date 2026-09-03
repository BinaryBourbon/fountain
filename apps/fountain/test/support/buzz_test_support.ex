defmodule Fountain.BuzzTestSupport do
  @moduledoc false

  @supervisor Fountain.BuzzSupervisor
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
        :ok

      _children ->
        Process.sleep(10)
        stop_all_harnesses!(tries - 1)
    end
  end
end
