defmodule Managoat.McpAuth.AsyncGlobalConfigGuardrailTest do
  use ExUnit.Case, async: true

  @moduledoc """
  An async test module must not write `:managoat_mcp_auth` application env.

  Application env is global. Tests that prove a config default must run in a
  synchronous module; pure URL-guard rules use `allow_private_hosts:` instead.
  """

  @async_use ~r/^\s*use\s+[\w.]+,\s*async:\s*true/m

  test "no async test module writes global application env" do
    root = Path.expand("../../..", __DIR__)

    offenders =
      root
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == Path.expand(__ENV__.file)))
      |> Enum.filter(fn file ->
        body = File.read!(file)

        Regex.match?(@async_use, body) and
          body
          |> String.split("\n")
          |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
          |> Enum.any?(&String.contains?(&1, "Application.put_env(:managoat_mcp_auth,"))
      end)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    assert offenders == [], """
    These async test modules write global :managoat_mcp_auth application env:

      #{Enum.join(offenders, "\n  ")}

    Move each config-writing test into a synchronous module.
    """
  end
end
