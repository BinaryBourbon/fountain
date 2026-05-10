defmodule Fountain.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    FountainWeb.Plugs.RateLimit.ensure_table()
    Fountain.Telemetry.attach_default_logger()

    # OpenTelemetry instrumentation (prod only — deps not compiled in dev/test).
    # apply/3 defers symbol resolution past compile time so dev/test compiles
    # don't warn about modules that aren't in their build.
    if Application.spec(:opentelemetry_phoenix) do
      apply(OpentelemetryPhoenix, :setup, [[adapter: :bandit]])
      apply(OpentelemetryEcto, :setup, [[:fountain, :repo]])
      Fountain.Telemetry.attach_otel_bridge()
    end

    cluster_topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        FountainWeb.Telemetry,
        Fountain.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:fountain, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:fountain, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Fountain.PubSub}
      ] ++
        cluster_children(cluster_topologies) ++
        [
          # Horde.Registry + Horde.DynamicSupervisor are CRDT-backed
          # cluster-aware replacements. Single-node behavior is
          # unchanged; on multiple nodes they sync state and let
          # processes be addressed across the cluster.
          {Horde.Registry,
           [name: Fountain.ConversationRegistry, keys: :unique, members: :auto]},
          {Horde.DynamicSupervisor,
           [
             name: Fountain.ConversationSupervisor,
             strategy: :one_for_one,
             distribution_strategy: Horde.UniformDistribution,
             members: :auto
           ]},
          FountainWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: Fountain.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup} ->
        # Rehydrate ConversationServers for non-terminal conversations whose
        # sprite was fully provisioned at the last clean stop. Done in a
        # detached process so a failure here doesn't block app boot.
        unless skip_rehydrate?(),
          do: Task.start(fn -> Fountain.Conversations.Rehydrator.run() end)

        {:ok, sup}

      err ->
        err
    end
  end

  defp cluster_children([]), do: []

  defp cluster_children(topologies) do
    [{Cluster.Supervisor, [topologies, [name: Fountain.ClusterSupervisor]]}]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FountainWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Tests opt out via config; everything else (mix phx.server, releases,
  # iex -S mix phx.server) should rehydrate so we recover from a clean
  # BEAM stop.
  defp skip_rehydrate? do
    Application.get_env(:fountain, :skip_rehydrate, false)
  end
end
