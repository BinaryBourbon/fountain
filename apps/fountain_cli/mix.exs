defmodule FountainCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :fountain_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [
        main_module: FountainCli,
        name: "fountain",
        app: nil,
        embed_elixir: true
      ]
    ]
  end

  def application do
    [
      mod: {FountainCli.Bootstrap, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.11"},
      {:sprites, github: "superfly/sprites-ex"},
      {:burrito, "~> 1.5", runtime: false}
    ]
  end
end
