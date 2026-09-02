defmodule Managoat.OAuth.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BinaryBourbon/fountain/tree/main/apps/managoat_oauth"

  def project do
    [
      app: :managoat_oauth,
      version: @version,
      # Umbrella-first (decisions/0037): this app builds into the umbrella's
      # _build and deps and shares its lockfile while it lives here. The three
      # path lines go when it graduates to a managoat/<name> repository.
      #
      # Deliberately no `config_path` pointing at the umbrella's config: that
      # config is Fountain's (config/runtime.exs calls Fountain modules), and
      # a library that reads no :fountain configuration has no use for it.
      # Run from this directory the app boots with no config at all, which is
      # what a consumer of the hex package gets too. The one thing it needs,
      # the host's repo, is read from the host's own otp_app under the
      # instance module's key (`config :my_app, MyApp.OAuth, repo: MyApp.Repo`)
      # and has no default: Managoat.OAuth.Config raises a message naming the
      # key rather than quietly finding no table.
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "OAuth 2.0 authorization code + PKCE and device grant state machine for public clients, behind a host behaviour that mints the token.",
      package: package(),
      test_coverage: [
        # What this suite measures on its own: the grant state machine, the
        # client registry, the config loader and the migration, driven through
        # a test instance against a recording host and the library's own
        # Postgres database. Raise it as the tests grow; never lower it.
        summary: [threshold: 85]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Schemas, queries and the migration helpers. The host supplies the
      # repo; this library starts none.
      {:ecto_sql, "~> 3.13"},
      # The library's own tests run against Postgres; a consumer brings the
      # adapter its repo uses.
      {:postgrex, ">= 0.0.0", only: :test}
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
