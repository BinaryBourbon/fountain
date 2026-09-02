defmodule Managoat.OAuth.AsyncGlobalConfigGuardrailTest do
  @moduledoc """
  An `async: true` test module must not write `Application.put_env(:managoat_oauth, ...)`
  under an instance key another test reads.

  Application env is global. ExUnit runs async modules concurrently, so a
  module that rewrites an instance's config changes it for every test running
  beside it, for as long as the write is held; the failure lands in a
  different file, on some seeds only. The instances the suite shares are
  configured once, in test/test_helper.exs; a test that needs config of its
  own writes it under a key of its own (config_test.exs does, under its own
  module name) or goes into an `async: false` module.

  This is the library's copy of the rule the sandbox and runner libraries
  and the host application's suite keep for their own config; each guardrail
  scans only its own test tree.
  """
  use ExUnit.Case, async: true

  @async_use ~r/^\s*use\s+[\w.]+,\s*async:\s*true/m
  @shared_keys ~w(Managoat.OAuth.TestRepo Managoat.OAuth.TestInstance Managoat.OAuth.PrefixedInstance Managoat.OAuth.UnconfiguredInstance)

  test "no async test module rewrites a shared instance's application env" do
    root = Path.expand("../..", __DIR__)
    files = Path.wildcard(Path.join(root, "test/**/*_test.exs"))

    assert files != [], "the guardrail found no test files — it would pass over anything"

    self = Path.relative_to(Path.expand(__ENV__.file), root)

    offenders =
      files
      |> Enum.reject(&(Path.relative_to(&1, root) == self))
      |> Enum.filter(fn abs ->
        body = File.read!(abs)
        Regex.match?(@async_use, body) and writes_shared_env?(body)
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert offenders == [], """
    These async test modules write a shared instance's application env:

    #{Enum.map_join(offenders, "\n", &"  #{&1}")}

    Configure shared instances in test/test_helper.exs, or use a key of your own.
    """
  end

  # A commented-out or quoted call is not a call.
  defp writes_shared_env?(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.any?(fn line ->
      String.contains?(line, "Application.put_env(:managoat_oauth,") and
        Enum.any?(@shared_keys, &String.contains?(line, &1))
    end)
  end
end
