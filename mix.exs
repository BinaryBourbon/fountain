defmodule Fountain.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      fountain_server: [
        applications: [fountain: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --app fountain mix ecto.setup"],
      "ecto.reset": ["cmd --app fountain mix ecto.reset"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict --mute-exit-status",
        "test"
      ]
    ]
  end
end
