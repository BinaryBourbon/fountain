defmodule Fountain.CI.TimingFormatter do
  @moduledoc """
  Records module durations without changing ExUnit's execution options.

  `--slowest-modules` forces trace mode, max_cases=1 and infinite timeouts.
  This second formatter observes events alongside the ordinary CLI formatter.
  Its output uses the format consumed by scripts/regen-test-timings.exs.
  """
  use GenServer

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, timings) do
    key = {test.module, test.tags.file}
    {:noreply, Map.update(timings, key, test.time, &(&1 + test.time))}
  end

  def handle_cast({:suite_finished, _times}, timings) do
    rows =
      for {{module, file}, us} <- Enum.sort(timings) do
        "#{inspect(module)} (#{Float.round(us / 1000, 1)}ms)\n [#{Path.relative_to_cwd(file)}]\n"
      end

    # One write prevents the CLI formatter's summary from splitting a
    # module/path pair and making it disappear from the timing parser.
    IO.write(["\nCI module timings (execution options unchanged):\n", rows])

    {:noreply, timings}
  end

  def handle_cast(_event, timings), do: {:noreply, timings}
end
