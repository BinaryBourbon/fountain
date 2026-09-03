defmodule Fountain.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      # Kept in lockstep with the newest v* git tag — release-bump.yml
      # computes the next tag from this value.
      version: "0.16.0",
      hex: [
        ignore_advisories: [
          # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
          # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "EEF-CVE-2026-43969",
          # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
          # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "EEF-CVE-2026-43971",
          # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
          # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "EEF-CVE-2026-43966",
          # gun 2.5.0 is already the newest Hex release, OSV lists no fixed Hex
          # version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "GHSA-w4f7-4cxr-rv3c"
        ]
      ],
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      # Built-in cover rather than ExCoveralls (#620): ExCoveralls has no way
      # to merge results from separate machines, and the suite is now run as
      # six partitions in six CI jobs, each of which instruments every
      # module while exercising a sixth of the tests. `mix test --partitions`
      # exports a .coverdata per partition and `mix test.coverage` merges them
      # here, at the umbrella root, where the 85% threshold is enforced once
      # against the union. Dropping the threshold per partition instead would
      # have deleted the gate while leaving it looking present.
      test_coverage: coverage(),
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
        # :mix so Mix.Task-based code (`mix openapi.spec.json`, the aliases)
        # analyzes cleanly — without it every Mix.* call is "unknown function".
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test
      ]
    ]
  end

  # Shared with apps/fountain/mix.exs — see coverage.exs for why it is a file.
  defp coverage do
    Path.expand("coverage.exs", __DIR__) |> Code.eval_file() |> elem(0)
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
        &deps_unlock_unused_changes_nothing/1,
        "format --check-formatted",
        "credo --strict",
        &dialyzer_in_dev/1,
        &sobelow_in_app/1,
        &release_assembles_in_prod/1,
        "test"
      ]
    ]
  end

  # Parity with CI's `mix deps.unlock --unused && git diff --exit-code
  # mix.lock`. The bare "deps.unlock --unused" step silently rewrote the
  # lockfile and passed, while CI failed the same commit on the diff check.
  # Compared against the pre-run file rather than git HEAD so an
  # uncommitted-but-legitimate lockfile edit (a dep added this branch) does
  # not trip it — only changes deps.unlock itself makes.
  defp deps_unlock_unused_changes_nothing(_args) do
    before = File.read!("mix.lock")
    Mix.Task.run("deps.unlock", ["--unused"])

    if File.read!("mix.lock") != before do
      Mix.raise(
        "mix.lock listed unused dependencies (deps.unlock --unused just pruned them). " <>
          "Commit the updated mix.lock — CI fails this via `git diff --exit-code mix.lock`."
      )
    end

    :ok
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

  # The only step here that builds :prod, and so the only one that can see a
  # dependency graph the dev and test builds do not have. apps/fountain scopes
  # the OpenTelemetry family `only: :prod`, which puts `chatterbox` (reached
  # through grpcbox under opentelemetry_exporter) in no dev or test build. When
  # the hackney 4 bump pulled in `h2`, whose modules collide with chatterbox's,
  # every other gate above stayed green while `mix release` refused to
  # assemble (#1472, #1477):
  #
  #   ** (Mix) Duplicated modules:
  #     h2_settings specified in chatterbox and h2
  #
  # Assemble only, not CI's boot check. Duplicate modules and the
  # application-mode validation are decided at assemble time, and assembling
  # needs no secrets: `mix release` reads config/runtime.exs to copy it in as a
  # config provider rather than to evaluate it. Booting is the half that needs
  # SECRET_KEY_BASE and a database, and CI keeps it.
  #
  # ~9s in a warm tree. A cold one also pays the first prod compile (~2 min),
  # once, and then caches it under _build/prod like any other env.
  #
  # `deps.get`, not CI's `deps.get --only prod`. `--only` *prunes* deps/ down
  # to that env, so running it here would delete credo, dialyxir, sobelow,
  # mimic and stream_data and leave the `test` step below dying on "Unchecked
  # dependencies for environment test". CI gets away with it because its job
  # ends at the release. Plain `deps.get` is env-agnostic and fetches nothing
  # when the tree is current, but it has to run: the steps above only check
  # :test and :dev deps, so the lockfile bump this gate exists for would
  # otherwise fail on "lock mismatch" instead of assembling.
  defp release_assembles_in_prod(_args) do
    env = [{"MIX_ENV", "prod"}]

    with 0 <- Mix.shell().cmd("mix deps.get", env: env),
         0 <- Mix.shell().cmd("mix release fountain_server --overwrite", env: env) do
      :ok
    else
      status ->
        Mix.raise(
          "the prod release failed to assemble (exit status #{status}). " <>
            "CI fails this in \"Static analysis and release checks\". A duplicate-module " <>
            "clash between a new dependency and a prod-only one is the usual cause."
        )
    end
  end

  # Not plain `mix sobelow`: at the umbrella root sobelow detects no Phoenix
  # app, scans nothing, and exits 0 — a gate that passes because it scanned
  # nothing looks identical to a gate that passed (#311). The script also
  # overlays ee/lib into the scan tree, which sobelow cannot reach from
  # apps/fountain on its own (decisions/0010).
  defp sobelow_in_app(_args) do
    case Mix.shell().cmd("scripts/sobelow.sh") do
      0 -> :ok
      status -> Mix.raise("sobelow failed with exit status #{status}")
    end
  end
end
