defmodule Managoat.Docs.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_docs"

  def project do
    [
      app: :managoat_docs,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # a library that reads no configuration at all has no use for it. Run
      # from this directory the app boots with no config, which is what a
      # consumer of the hex package gets too. Everything the library needs is
      # on the host's `use Managoat.Docs` line.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "A documentation manual embedded at compile time for a Phoenix app to serve, its sanitising markdown renderer, and the guardrail tests that keep it sound.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own: the compiler, the renderer and
        # the checks, driven by the fixture manual. Raise it as the library's
        # own tests grow; never lower it.
        summary: [threshold: 90],
        # The two `use` macros run at test-compile time, before cover
        # instruments anything, so they always report 0%. They are exercised
        # by the fixture module and by docs_test.exs (and by every host's
        # guardrail file) rather than measured.
        ignore_modules: [Managoat.Docs, Managoat.Docs.GuardrailCase]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # The fixture manual's docs module lives in test/support: it `use`s the
  # macro against test/fixtures/manual, so it is a test-only compile.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # comrak, through MDEx. Every page renders through it, both paths.
      {:mdex, "~> 0.13.5"},
      # Syntax highlighting for the trusted path. Called directly rather than
      # through MDEx's integration, which needs a NIF build an order of
      # magnitude larger (147 MB unpacked against 12 MB); see
      # `Managoat.Docs.Markdown`.
      {:lumis, "~> 0.7"},
      # The pre-encoded search index.
      {:jason, "~> 1.2"}
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
