defmodule Managoat.Runner.AsyncGlobalConfigGuardrailTest do
  @moduledoc """
  An `async: true` test module must not write `Application.put_env(:managoat_runner, ...)`.

  Application env is global. ExUnit runs async modules concurrently, so a
  module that writes host config changes it for every test running beside
  it, for as long as the write is held; the failure lands in a different
  file, on some seeds only. The config test that clears the host is
  `async: false` for exactly this reason, and a test that needs to write
  config goes into a sibling `async: false` module (see config_test.exs),
  never into an async one.

  This is the library's copy of the rule the sandbox library and the host
  application's suite keep for their own config; each guardrail scans only
  its own test tree.
  """
  use ExUnit.Case, async: true

  @async_use ~r/^\s*use\s+[\w.]+,\s*async:\s*true/m

  test "no async test module writes global application env" do
    root = Path.expand("../..", __DIR__)
    files = Path.wildcard(Path.join(root, "test/**/*_test.exs"))

    assert files != [], "the guardrail found no test files — it would pass over anything"

    self = Path.relative_to(Path.expand(__ENV__.file), root)

    offenders =
      files
      |> Enum.reject(&(Path.relative_to(&1, root) == self))
      |> Enum.filter(fn abs ->
        body = File.read!(abs)
        Regex.match?(@async_use, body) and writes_env?(body)
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert offenders == [], """
    These async test modules write global application env:

    #{Enum.map_join(offenders, "\n", &"  #{&1}")}

    Move the tests that write config into a sibling `async: false` module —
    see config_test.exs.
    """
  end

  # A commented-out or quoted call is not a call.
  defp writes_env?(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.any?(&String.contains?(&1, "Application.put_env(:managoat_runner,"))
  end
end
