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

  # ── reverse direction (#337) ─────────────────────────────────────────────
  #
  # The original test only caught runtime.exs → doc drift. Nothing caught a
  # documented variable that no longer exists in code, or a compose variable
  # the app never reads — an operator following either would set a knob wired
  # to nothing.

  # Documented variables legitimately read outside config/runtime.exs.
  # Each entry needs a reason; an entry without a real reader is exactly the
  # rot this test exists to catch.
  @read_elsewhere %{
    # The OTel SDK reads its own standard variables directly.
    "OTEL_TRACES_EXPORTER" => "read by the OTel Erlang SDK",
    # Set by release tooling; read in Fountain.Application.skip_migrations?/0.
    "RELEASE_NAME" => "release tooling + Fountain.Application"
  }

  test "every variable documented in configuration.md is actually read by code" do
    source = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    doc = File.read!(Path.join(@repo_root, "docs/configuration.md"))

    documented =
      Regex.scan(~r/^\| `([A-Z][A-Z0-9_]*)`/m, doc, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    # Vacuous-pass guard, mirroring the forward test.
    assert length(documented) > 30,
           "extracted only #{length(documented)} documented vars — the table format changed"

    dead =
      Enum.reject(documented, fn var ->
        String.contains?(source, ~s("#{var}")) or Map.has_key?(@read_elsewhere, var)
      end)

    assert dead == [],
           """
           docs/configuration.md documents variables that config/runtime.exs never reads:

             #{Enum.join(dead, ", ")}

           Delete the row, or — only when a real reader exists outside
           runtime.exs — add the var to @read_elsewhere with the reader.
           """
  end

  # Compose-side keys that are not app env vars: consumed by compose
  # interpolation or by another service, not by the release.
  @compose_only ~w()

  test "every env var the compose app service sets is one the app reads" do
    source = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    # The environment mapping of the `app:` service: keys at 6-space indent
    # between its `environment:` line and the next 4-space-indented key.
    [_, app_section] = String.split(compose, ~r/^  app:\n/m, parts: 2)
    [_, env_and_rest] = String.split(app_section, ~r/^    environment:\n/m, parts: 2)
    [env_block | _] = String.split(env_and_rest, ~r/^    [a-z]/m, parts: 2)

    keys =
      Regex.scan(~r/^      ([A-Z][A-Z0-9_]*):/m, env_block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(keys) > 5,
           "extracted only #{length(keys)} compose env keys — the compose layout changed"

    unread =
      Enum.reject(keys, fn var ->
        String.contains?(source, ~s("#{var}")) or var in @compose_only or
          Map.has_key?(@read_elsewhere, var)
      end)

    assert unread == [],
           """
           docker-compose.yml sets env vars on the app service that the app never reads:

             #{Enum.join(unread, ", ")}

           Remove the key, or add it to @compose_only/@read_elsewhere with a reason.
           """
  end

  # Keys in .env.compose.example consumed by compose interpolation itself
  # (image tag, published ports, sibling services), not passed through the
  # app service's environment block.
  @interpolation_only ~w(FOUNTAIN_IMAGE_TAG PORT POSTGRES_PASSWORD POSTGRES_HOST_PORT)

  test "every variable .env.compose.example advertises is actually passed to the app" do
    # The other compose test is one-directional by construction: it asserts
    # every key compose SETS is read, never that every key the example file
    # ADVERTISES is passed through. That gap is exactly how a documented
    # variable can be set by an operator and silently ignored.
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))
    example = File.read!(Path.join(@repo_root, ".env.compose.example"))

    advertised =
      Regex.scan(~r/^#?\s*([A-Z][A-Z0-9_]*)=/m, example, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(advertised) > 5,
           "extracted only #{length(advertised)} keys from .env.compose.example — its layout changed"

    unpassed =
      Enum.reject(advertised, fn var ->
        passed_through?(compose, var) or var in @interpolation_only
      end)

    assert unpassed == [],
           """
           .env.compose.example advertises variables the compose file never passes to the app:

             #{Enum.join(unpassed, ", ")}

           Add the key to the app service's environment block, or to
           @interpolation_only with a reason.
           """
  end

  test "every variable a guide tells the reader to append to .env is passed to the app" do
    # The two tests above both run "declared, therefore it must be real": they
    # start from what compose sets or what the example file advertises. Neither
    # starts from what a *guide* tells an operator to do, which is how
    # API_CORS_ORIGINS came to be documented, read by runtime.exs, instructed
    # by the deploy guide — and never forwarded by compose, so following the
    # guide changed nothing and logged nothing (#1215).
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    instructed =
      Path.join(@repo_root, "docs/**/*.md")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/^echo\s+"([A-Z][A-Z0-9_]*)=.*>>\s*\.env\s*$/m, &1))
        |> Enum.map(fn [_, var] -> {var, Path.relative_to(path, @repo_root)} end)
      end)
      |> Enum.uniq()

    assert instructed != [],
           "found no `>> .env` lines in docs/ — the guides changed shape, so this guard is blind"

    unpassed = Enum.reject(instructed, fn {var, _} -> passed_through?(compose, var) end)

    assert unpassed == [],
           """
           A guide tells the reader to append variables that compose never passes to the app,
           so following it silently does nothing:

             #{Enum.map_join(unpassed, "\n  ", fn {var, path} -> "#{var} (#{path})" end)}

           Add the key to the app service's environment block in docker-compose.yml.
           """
  end

  # Two legitimate pass-through forms in the app service's environment block:
  # `VAR: ${VAR...}` with any default, and a bare `VAR:` with no value at all.
  # The second one forwards the variable only when .env sets it, which is the
  # only way to distinguish "unset, use the app's default" from "set to empty
  # on purpose" — see the app-URL block in docker-compose.yml.
  defp passed_through?(compose, var) do
    Regex.match?(~r/^\s*#{var}:\s*.*\$\{#{var}[:}-]/m, compose) or
      Regex.match?(~r/^\s*#{var}:\s*$/m, compose)
  end
end
