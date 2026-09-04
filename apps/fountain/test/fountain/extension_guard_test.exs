defmodule Fountain.ExtensionGuardTest do
  @moduledoc """
  The compile-time boundary, checked as source (ADR 0043, #1507).

  The umbrella's dependency resolution proves `fountain_buzz -> fountain`: the
  extension lists `{:fountain, in_umbrella: true}` and Fountain lists nothing.
  It proves nothing at all about the other direction, because the way that
  breaks is not a dependency — it is a stray module atom, a route, a migration
  or a config key that compiles perfectly and only surprises somebody on the
  day a core-only release fails to boot.

  So this walks the source. It is the test that has to fail on the PR that
  reintroduces the crossing, not on the deploy.

  ## What is allowed

  Prose. `apps/fountain/lib` may say the word "Buzz" in a comment, a docstring
  or a schema description, and does — the ADR calls that human-facing
  discovery metadata. `/buzz-launch` is a marketing page about the integration
  and is core's, like every other marketing page. What is refused is *code*
  that names the extension.

  `config/` is deliberately not walked: naming an extension module in
  configuration is the one place ADR 0043 says it belongs.
  """
  use ExUnit.Case, async: true

  @core_lib Path.expand("../../lib", __DIR__)

  @sources @core_lib
           |> Path.join("**/*.{ex,exs,heex}")
           |> Path.wildcard()
           |> Enum.sort()

  # Module references, not the product's name. `FountainBuzz.Thing`,
  # `Fountain.Buzz.Thing`, and the two Horde names the tree used to carry.
  @module_reference ~r/\b(FountainBuzz\.|Fountain\.Buzz\b|Fountain\.BuzzRegistry\b|Fountain\.BuzzSupervisor\b|Fountain\.Workers\.BuzzHarnessSweep\b|FountainWeb\.Buzz[A-Z])/

  test "apps/fountain/lib names no extension module" do
    offenders =
      for path <- @sources,
          {line, number} <- Enum.with_index(File.stream!(path), 1),
          Regex.match?(@module_reference, line),
          do: "#{Path.relative_to(path, @core_lib)}:#{number}: #{String.trim(line)}"

    assert offenders == [],
           """
           Core source names an extension module. It must reach an extension only
           through `Fountain.Extension` callbacks, read from
           `config :fountain, :extensions` (ADR 0043).

           #{Enum.join(offenders, "\n")}
           """
  end

  test "apps/fountain/lib declares no Buzz route" do
    router = Path.join(@core_lib, "fountain_web/router.ex")

    offenders =
      for {line, number} <- Enum.with_index(File.stream!(router), 1),
          Regex.match?(~r|"/(api/)?(mcp/)?buzz|, line),
          # The marketing page is core's, like every other marketing page.
          not String.contains?(line, "buzz-launch"),
          do: "router.ex:#{number}: #{String.trim(line)}"

    assert offenders == [],
           "The core router declares a Buzz route:\n#{Enum.join(offenders, "\n")}"
  end

  test "apps/fountain/priv holds no Buzz migration or asset" do
    priv = Path.expand("../../priv", __DIR__)

    offenders =
      priv
      |> Path.join("**/*buzz*")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, priv))

    assert offenders == [],
           """
           Buzz assets and migrations belong to the extension's priv, so that a
           core-only release carries neither. Found:

           #{Enum.join(offenders, "\n")}
           """
  end

  test "the extension depends on the host, and the host depends on no extension" do
    core_mix = Path.expand("../../mix.exs", __DIR__) |> File.read!()
    ext_mix = Path.expand("../../../fountain_buzz/mix.exs", __DIR__) |> File.read!()

    assert ext_mix =~ "{:fountain, in_umbrella: true}"

    refute core_mix =~ ":fountain_buzz",
           "apps/fountain must not depend on the extension; the release owns inclusion"
  end

  test "the bundled release includes both apps" do
    umbrella_mix = Path.expand("../../../../mix.exs", __DIR__) |> File.read!()

    assert umbrella_mix =~ "fountain: :permanent",
           "the bundled release must include the server"

    assert umbrella_mix =~ "fountain_buzz: :permanent",
           "the bundled release must include the Buzz extension (ADR 0043 decision 7)"
  end
end
