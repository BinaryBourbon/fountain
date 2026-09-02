defmodule Managoat.ACP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_acp"

  def project do
    [
      app: :managoat_acp,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # this library reads no configuration at all. Everything the peer and
      # the policy need arrives as an argument: the writer, the policy map,
      # the configured ask timeout. Run from this directory the app boots
      # with no config, which is what a consumer of the hex package gets too.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "A client-side Agent Client Protocol session that outlives the turn, with a per-tool permission policy, block normalisation, usage accounting and a tracer, behind a writer callback.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own, set from the first
        # `mix test --cover` run after extraction (#1339) rather than to
        # pass. Raise it as the library's own tests grow; never lower it.
        summary: [threshold: 90]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      # The tracer opens and closes OTel spans through the API macros
      # (`OpenTelemetry.Tracer`). The API package is the portable half of
      # OpenTelemetry: with no SDK started every span call is a no-op, so a
      # consumer that does not trace pays nothing and configures nothing.
      # The SDK, the exporter and the instrumentation libraries belong to
      # the host application.
      {:opentelemetry_api, "~> 1.4"}
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
