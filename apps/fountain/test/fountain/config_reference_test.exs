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

  # The environment mapping of the `app:` service: keys at 6-space indent
  # between its `environment:` line and the next 4-space-indented key.
  defp compose_app_env_keys(compose) do
    [_, app_section] = String.split(compose, ~r/^  app:\n/m, parts: 2)
    [_, env_and_rest] = String.split(app_section, ~r/^    environment:\n/m, parts: 2)
    [env_block | _] = String.split(env_and_rest, ~r/^    [a-z]/m, parts: 2)

    Regex.scan(~r/^      ([A-Z][A-Z0-9_]*):/m, env_block, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "every env var the compose app service sets is one the app reads" do
    source = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    keys = compose_app_env_keys(compose)

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

  # ── advertised → passed through (#397) ───────────────────────────────────
  #
  # The compose `environment:` block is a closed allowlist: only the keys it
  # names reach the container. The test above is one-directional by
  # construction — it checks every key compose *sets* is read, never that
  # every variable the example file *advertises* is passed through. That gap
  # is how SPRITES_BASE_URL, CHECK_ORIGIN_EXTRA, the sandbox bounds and
  # REGISTRATION_ALLOWED_EMAIL_DOMAINS shipped in .env.compose.example while
  # silently doing nothing.

  # Consumed by compose interpolation itself, never by the app process:
  #   FOUNTAIN_IMAGE_TAG — the app image tag (`image:` line)
  #   POSTGRES_PASSWORD  — postgres/backup services and the DATABASE_URL
  #                        interpolation; the app only sees the composed URL
  #   PORT               — the host side of the port mapping; the container
  #                        side is pinned to 4000
  @interpolation_only ~w(FOUNTAIN_IMAGE_TAG POSTGRES_PASSWORD PORT)

  test "every variable advertised in .env.compose.example reaches the app service" do
    example = File.read!(Path.join(@repo_root, ".env.compose.example"))
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    # A key is "advertised" when a line offers it for the operator to set:
    # either active (`KEY=`) or commented out as an example (`# KEY=value`).
    advertised =
      Regex.scan(~r/^(?:# )?([A-Z][A-Z0-9_]*)=/m, example, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    # Vacuous-pass guard, mirroring the other tests in this file.
    assert length(advertised) > 10,
           "extracted only #{length(advertised)} advertised keys — the example format changed"

    passed = compose_app_env_keys(compose)

    dropped =
      Enum.reject(advertised, fn var ->
        var in passed or var in @interpolation_only
      end)

    assert dropped == [],
           """
           .env.compose.example advertises variables the compose app service never passes through:

             #{Enum.join(dropped, ", ")}

           Setting them in .env silently does nothing. Add each to the app
           service's environment: block (as ${VAR:-} or with the app's own
           default), or — only for keys compose itself consumes during
           interpolation — add them to @interpolation_only with a reason.
           """
  end
end
