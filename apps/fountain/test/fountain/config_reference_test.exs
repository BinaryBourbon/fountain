defmodule Fountain.ConfigReferenceTest do
  use ExUnit.Case, async: true

  # Guards docs/configuration.md against drifting from config/runtime.exs
  # (#280): every environment variable the runtime config reads must have a
  # row in the reference. Reading a new var without documenting it is a red
  # build, not an archaeology project.

  @repo_root Path.expand("../../../..", __DIR__)

  # Injected by the platform or release tooling rather than set by an
  # operator; not part of the operator-facing reference.
  @platform_injected ~w(FLY_APP_NAME)

  test "every env var read in config/runtime.exs is documented in docs/configuration.md" do
    source = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    doc = File.read!(Path.join(@repo_root, "docs/configuration.md"))

    # Two extraction passes: direct System.get_env/fetch_env calls, plus any
    # quoted UNDERSCORED_ALL_CAPS literal — the latter catches vars passed
    # through helpers like parse_bound.("SANDBOX_IDLE_TIMEOUT_MINUTES", ...),
    # which the direct pattern misses.
    direct =
      Regex.scan(
        ~r/System\.(?:get_env|fetch_env!?)\(\s*"([A-Z][A-Z0-9_]*)"/,
        source,
        capture: :all_but_first
      )

    underscored_literals =
      Regex.scan(~r/"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)"/, source, capture: :all_but_first)

    vars =
      (direct ++ underscored_literals)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    # If extraction ever stops matching (a refactor of runtime.exs, a regex
    # rot), this guard fails loudly instead of the main assertion passing
    # vacuously over an empty list.
    assert length(vars) > 30,
           "extracted only #{length(vars)} env vars from config/runtime.exs — " <>
             "the extraction patterns no longer match how the file reads env vars"

    undocumented =
      Enum.reject(vars, fn var ->
        var in @platform_injected or String.contains?(doc, "`#{var}`")
      end)

    assert undocumented == [],
           """
           config/runtime.exs reads env vars that docs/configuration.md does not document:

             #{Enum.join(undocumented, ", ")}

           Add a row for each (in backticks), or — only for vars the platform
           injects rather than an operator sets — add them to @platform_injected.
           """
  end
end
