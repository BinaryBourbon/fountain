defmodule Managoat.Broker.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_broker"

  def project do
    [
      app: :managoat_broker,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # this library reads no configuration at all. Everything the listener
      # needs (the port, the session store, the CA seed) is a start argument,
      # because the host computed those values at boot and a library that is
      # not started serves nothing. Run from this directory the app boots
      # with no config, which is what a consumer of the hex package gets too.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "An egress credential proxy for sandboxed agents: CONNECT and absolute-form forward proxy that attaches the real credential where the sandbox sent a placeholder, behind a session-store behaviour.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own: the proxy end to end against a
        # real Bandit HTTPS origin, the CA, the injector, the HTTP slice and
        # the in-memory store. Raise it as the library's own tests grow;
        # never lower it.
        summary: [threshold: 85]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  # The end-to-end rig (a Bandit origin, the sandbox-shaped client) is test
  # support, not part of the package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The listener. Bandit sits on the same library, so a Phoenix host
      # already has it; it is named here because the proxy handler is written
      # against it directly.
      {:thousand_island, "~> 1.5"},
      # Certificate building for the derived root and the per-host leaves.
      # Pure Elixir over :public_key.
      {:x509, "~> 0.9"},
      {:telemetry, "~> 1.0"},
      # Test only: a real HTTPS origin behind the proxy, a WebSocket echo on
      # it, and JSON for what the origin echoes back. jason is :dev as well
      # because credo depends on it in :dev; with only :test here, Mix
      # refuses the divergence once the library stands alone.
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:jason, "~> 1.2", only: [:dev, :test]}
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
