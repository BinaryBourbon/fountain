defmodule Managoat.Runner.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_runner"

  def project do
    [
      app: :managoat_runner,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # a library that reads no :fountain configuration has no use for it.
      # Run from this directory the app boots with no config at all, which is
      # what a consumer of the hex package gets too. The one setting it reads,
      # `config :managoat_runner, host: Module`, has no default on purpose:
      # Managoat.Runner.Config.host!/1 raises a message naming the key rather
      # than quietly finding no runner online.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "The self-hosted runner wire protocol: a WebSock connection process and a Managoat.Sandbox adapter over it, behind a host behaviour.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own: the connection, the adapter,
        # the names, the two hosts and the fake daemon, all driven end to end
        # by the conformance suite against Managoat.Runner.Host.Local. Raise
        # it as the library's own tests grow; never lower it.
        summary: [threshold: 85]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      # The behaviour, Handle, Command, Session, NetworkPolicy and the
      # conformance case. The direction runner -> sandbox is the one
      # decisions/0037 pins. From hex since managoat_sandbox graduated
      # (#1345): the umbrella resolves it the same way apps/fountain does,
      # and `mix hex.build` for this app succeeds inside the umbrella, which
      # is what lets it graduate next.
      {:managoat_sandbox, "~> 0.1.0"},
      # The WebSock behaviour only. The adapter that mounts a handler on a
      # Plug connection (websock_adapter) belongs to the host application.
      {:websock, "~> 0.5"},
      {:jason, "~> 1.2"}
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
