defmodule Fountain.MixProject do
  use Mix.Project

  def project do
    [
      app: :fountain,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [muzak: :test]
    ]
  end

  def application do
    [
      mod: {Fountain.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:earmark, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # ravi-hq fork: includes the filesystem URL fix (/v1/sprites/<name>/fs/*)
      # and the attach_session URL fix. Upstream `superfly/sprites-ex` returns
      # 404 from `Filesystem.write`, so the bundled `fountain` SKILL.md silently
      # never landed on sprites. Pin to the post-merge commit on `main`.
      {:sprites, github: "ravi-hq/sprites-ex", ref: "c2a96426331f0e367455e838fea4ab4154032215"},
      {:open_api_spex, "~> 3.21"},
      {:libcluster, "~> 3.4"},
      {:horde, "~> 0.9.0"},
      # The opentelemetry_* family depends on complex Erlang/rebar3 cross-dep includes
      # (otel_sampler.hrl, grpcbox, chatterbox). They compile correctly in CI
      # (Alpine/musl OTP) but fail with rebar3 bare compile in some dev environments.
      # opentelemetry_api is the only one needed at compile time (for the @decorate macros);
      # the SDK and exporter are runtime-only outside of prod.
      {:opentelemetry, "~> 1.5", only: :prod},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8", only: :prod},
      {:opentelemetry_phoenix, "~> 2.0", only: :prod},
      {:opentelemetry_ecto, "~> 1.2", only: :prod},
      {:opentelemetry_telemetry, "~> 1.1", only: :prod},
      {:req, "~> 0.5"},
      # New Fountain deps
      {:bcrypt_elixir, "~> 3.0"},
      {:uniq, "~> 0.6"},
      {:stripity_stripe, "~> 3.0"},
      {:swoosh, "~> 1.17"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
      # Test / dev
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mimic, "~> 1.7", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:muzak, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["test"]
    ]
  end
end
