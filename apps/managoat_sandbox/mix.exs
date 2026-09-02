defmodule Managoat.Sandbox.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_sandbox"

  def project do
    [
      app: :managoat_sandbox,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # a library that reads no :fountain configuration has no use for it.
      # Run from this directory the app boots with no config at all, which is
      # what a consumer of the hex package gets too; every adapter setting is
      # read through Managoat.Sandbox.Config with a default.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "One sandbox behaviour over Sprites, E2B and Daytona, with the conformance suite a fourth adapter runs against.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own (the adapters are exercised
        # further by Fountain's provisioning tests, which count toward the
        # umbrella's 85% merged gate, not this one). Raise it as the library's
        # own tests grow; never lower it.
        summary: [threshold: 65],
        # The conformance case is macros: its bodies run at test-compile time,
        # before cover instruments anything, so it always reports 0%. It is
        # exercised by fake_conformance_test.exs (and by every adapter's
        # conformance run) rather than measured.
        ignore_modules: [~r/^Managoat\.Sandbox\.ConformanceCase/]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Upstream, at the tag. The `ravi-hq` fork this used to pin existed for
      # the filesystem URL fix (/v1/sprites/<name>/fs/*) and the
      # attach_session URL fix; both are upstream as of v0.2.0, and the fork
      # branched before the exit-frame fixes that #880 needed.
      #
      # A git dependency is what keeps this package off hex (decisions/0037):
      # graduation needs a hex release of sprites-ex or a vendored client.
      {:sprites, github: "superfly/sprites-ex", tag: "v0.2.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      # Test / dev
      {:mimic, "~> 2.3", only: :test},
      # Req.Test and the Plug.Conn helpers the adapter tests stub with.
      {:plug, "~> 1.16", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
