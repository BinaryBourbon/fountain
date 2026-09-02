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
      # The hex release, pinned exactly. hex 0.2.0 is byte-identical to the
      # superfly/sprites-ex tag v0.2.0 this used to pin as a git dependency
      # (which is what kept the package off hex; decisions/0037). 0.2.2 changes
      # the close-frame contract: a stream that closes without an exit frame
      # becomes `{:error, _, :closed_before_exit}` rather than `{:exit, _, 0}`,
      # which the adapter and the conformance suite must be revisited for
      # before the requirement is loosened. Do not widen this to `~> 0.2`
      # without that work.
      {:sprites, "0.2.0"},
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
