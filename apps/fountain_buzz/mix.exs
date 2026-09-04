defmodule FountainBuzz.MixProject do
  use Mix.Project

  @moduledoc """
  The Buzz extension (ADR 0043, tracker #1503).

  A first-party Fountain extension: an OTP application that depends on
  `:fountain`, is compiled into the bundled release, and is switched on by
  naming `FountainBuzz.Extension` in `config :fountain, :extensions`.

  AGPL-3.0-or-later, like `apps/fountain` and unlike a `managoat_*` component
  library (ADR 0037): this is databaseful, Fountain-specific product code that
  depends on the server, not a reusable Apache library. It is not published to
  hex and carries no promise of reusability.
  """

  def project do
    [
      app: :fountain_buzz,
      version: "0.16.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: coverage()
    ]
  end

  defp coverage do
    Path.expand("../../coverage.exs", __DIR__) |> Code.eval_file() |> elem(0)
  end

  def application do
    [
      # Its own supervision tree, not children handed to the host. Because this
      # app depends on :fountain, OTP starts the host first and stops it last,
      # so the Repo is up before this tree and this tree is down before the
      # Repo goes away — and a crash here cannot reach the host's supervisor
      # (ADR 0043, amended by #1505).
      mod: {FountainBuzz.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The one dependency, and it points one way. Fountain must never declare
      # a dependency on :fountain_buzz; the distribution owns inclusion of both.
      {:fountain, in_umbrella: true}
    ]
  end
end
