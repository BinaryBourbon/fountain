Code.require_file("timing-formatter.exs", __DIR__)
ExUnit.start(max_cases: 8, formatters: [ExUnit.CLIFormatter, Fountain.CI.TimingFormatter])

defmodule Fountain.CI.TimingFormatterTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Fountain.CI.TimingFormatter

  test "timing collection preserves concurrency and finite test timeouts" do
    config = ExUnit.configuration()
    assert config[:max_cases] == 8
    refute config[:trace]
    assert config[:timeout] == 60_000
  end

  test "aggregates test durations per module in the regeneration format" do
    test = %ExUnit.Test{module: Example, time: 1200, tags: %{file: "/tmp/example_test.exs"}}
    {:ok, timings} = TimingFormatter.init([])
    {:noreply, timings} = TimingFormatter.handle_cast({:test_finished, test}, timings)
    {:noreply, timings} = TimingFormatter.handle_cast({:test_finished, test}, timings)
    output = capture_io(fn -> TimingFormatter.handle_cast({:suite_finished, %{}}, timings) end)
    assert output =~ "Example (2.4ms)"
    assert output =~ "example_test.exs]"
  end
end
