defmodule Managoat.Runtimes.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_runtimes"

  def project do
    [
      app: :managoat_runtimes,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # this library reads no configuration at all. Credentials arrive as an
      # argument to `default_env/2`, the skills to install as an argument to
      # `Skills.install/3`, and the one timeout that used to be read here (how
      # long a held permission waits for a human) is the host's to read and
      # pass to the peer. Run from this directory the app boots with no
      # config, which is what a consumer of the hex package gets too.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "How a coding agent CLI (claude, codex, gemini, opencode) gets into a sandbox and comes up speaking ACP: the adapter pins, the file layout, the instructions file, the credential env vars, the skills tree, and the per-runtime workarounds with their deletion conditions.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own: 94.19% on the first
        # `mix test --cover` run after extraction (#1368), with the runtimes'
        # bootstraps, the adapter install and the skills mechanism driven
        # against a stubbed sandbox. Set a little under that so an added
        # error branch does not fail the gate on its own; raise it as the
        # library's own tests grow, never lower it.
        summary: [threshold: 90]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The sandbox the runtimes are provisioned into: exec, write_file,
      # spawn, the Handle and Retry. Both directions decisions/0037 pins.
      {:managoat_sandbox, "~> 0.1.0"},
      # Protocol.initialize_params/1 and default_client_capabilities/0, for
      # the params a host sends the adapter this library installed.
      {:managoat_acp, "~> 0.1.0"},
      # The runtime config files (claude's .mcp.json and settings.json,
      # gemini's settings.json) are JSON.
      {:jason, "~> 1.2"},
      {:mimic, "~> 2.3", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      # priv/ carries the gemini session-store consolidation script, which
      # Gemini.SessionStore embeds at compile time.
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end
end
