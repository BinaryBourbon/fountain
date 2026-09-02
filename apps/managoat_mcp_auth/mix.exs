defmodule Managoat.McpAuth.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_mcp_auth"

  def project do
    [
      app: :managoat_mcp_auth,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # a library that reads no :fountain configuration has no use for it.
      # Run from this directory the app boots with no config at all, which is
      # what a consumer of the hex package gets too.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "MCP authorization discovery with a server-side URL guard.",
      package: package(),
      test_coverage: [summary: [threshold: 70]]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      # Req keeps Plug optional; Req.Test's concurrent HTTP stubs need it only
      # while this library's tests run. It is not a package runtime dependency.
      {:plug, "~> 1.0", only: :test}
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
