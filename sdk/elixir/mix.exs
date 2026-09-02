defmodule FountainSdk.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :fountain_sdk,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Official Elixir SDK for Fountain",
      source_url: "https://github.com/BinaryBourbon/fountain",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/BinaryBourbon/fountain"}
      ],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md", "LICENSE"],
        source_url_pattern:
          "https://github.com/BinaryBourbon/fountain/blob/main/sdk/elixir/%{path}#L%{line}"
      ]
    ]
  end

  def application,
    do: [mod: {FountainSdk.Application, []}, extra_applications: [:logger, :ssl]]

  def cli, do: [preferred_envs: ["contract.verify": :test]]

  defp aliases do
    ["contract.verify": ["test test/contract_test.exs"]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:finch, "~> 0.23.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
