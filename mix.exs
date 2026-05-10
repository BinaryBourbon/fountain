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
      {:burrito, "~> 1.5", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      fountain: [
        applications: [fountain_cli: :permanent, runtime_tools: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito:
          Keyword.merge(burrito_targets(skip_nifs: true),
            extra_steps: [fetch: [pre: [Fountain.Burrito.InjectMuslPath]]]
          )
      ],
      fountain_server: [
        applications: [fountain_cli: :permanent, fountain: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: burrito_targets_with_musl_fix()
      ]
    ]
  end

  defp burrito_targets(opts \\ []) do
    skip_nifs = Keyword.get(opts, :skip_nifs, false)

    all_targets = [
      linux: [os: :linux, cpu: :x86_64, skip_nifs: skip_nifs],
      macos: [
        os: :darwin,
        cpu: :aarch64,
        custom_erts:
          "https://github.com/jhgaylor/aod-ex/releases/download/vendor-erts-otp-28.4/otp_28.4_macos_universal.tar.gz",
        skip_nifs: skip_nifs
      ]
    ]

    selected =
      case System.get_env("BURRITO_TARGETS") do
        nil ->
          all_targets

        "" ->
          all_targets

        list ->
          keys =
            list
            |> String.split(",", trim: true)
            |> Enum.map(&(String.trim(&1) |> String.to_atom()))

          Keyword.take(all_targets, keys)
      end

    [targets: selected, debug: Mix.env() != :prod]
  end

  defp burrito_targets_with_musl_fix do
    Keyword.merge(burrito_targets(),
      extra_steps: [fetch: [pre: [Fountain.Burrito.InjectMuslPath]]]
    )
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
