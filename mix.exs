defmodule Fountain.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      # Kept in lockstep with the newest v* git tag — release-bump.yml
      # computes the next tag from this value.
      version: "0.3.0",
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        # A fixed path (rather than the _build default) so CI can cache the
        # PLT across runs — cold PLT builds on a runner take minutes.
        #
        # list_unused_filters is deliberately NOT set: the pinned dialyxir ref
        # fails to credit string-form filters as used and would fail the run.
        # Audit the ignore file by hand with `mix dialyzer --list-unused-filters`
        # (tuple entries report accurately) when trimming it.
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        # :mix so Mix.Task-based tasks (mix fountain.verify_lifecycle)
        # analyze cleanly — without it every Mix.* call is "unknown function"
        # and the task's whole call graph degrades to no_return noise.
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Pinned to master: 1.4.7 (the latest hex release) does not know OTP 28's
      # :exact_compare warning class and its formatter crashes on it. This ref
      # is the commit that added OTP 28 support (jeremyjh/dialyxir#591) — drop
      # back to a hex requirement at the first release that includes it.
      {:dialyxir,
       github: "jeremyjh/dialyxir",
       ref: "3553678f4d69281ac6db61034bcf35bcb30cfd78",
       only: [:dev, :test],
       runtime: false}
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
        "credo --strict",
        &dialyzer_in_dev/1,
        "test"
      ]
    ]
  end

  # MIX_ENV=dev on purpose (precommit itself runs in :test): dialyzer analyzes
  # the shipped code, and the test env would drag test/support and test-only
  # deps (ex_unit, mimic) into the analysis and the PLT. A function rather than
  # "cmd ..." because `mix cmd` execs without a shell and, in an umbrella, once
  # per child app.
  defp dialyzer_in_dev(_args) do
    case Mix.shell().cmd("mix dialyzer", env: [{"MIX_ENV", "dev"}]) do
      0 -> :ok
      status -> Mix.raise("mix dialyzer failed with exit status #{status}")
    end
  end
end
