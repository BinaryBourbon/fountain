defmodule Fountain.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    FountainWeb.Plugs.RateLimit.ensure_table()
    Fountain.Telemetry.attach_default_logger()
    attach_sentry_handler()

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
        {Phoenix.PubSub, name: Fountain.PubSub},
        FountainWeb.Plugs.RateLimit.Sweeper,
        Fountain.Conversations.Redaction,
        {Oban, Application.fetch_env!(:fountain, Oban)}
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
             members: :auto,
             # Explicit, and sized to the fleet: the default (3 restarts in
             # 5s) is a budget SHARED by every ConversationServer on the
             # node — one child that crashes deterministically on start
             # exhausts it in under a second, and exceeding it terminates
             # this supervisor and with it every running conversation here.
             # 100/10s tolerates a correlated transient burst (a Sprites
             # outage failing many provisions at once) while still stopping
             # a genuine infinite loop. The known deterministic crash paths
             # (rows deleted before handle_continue(:provision)) are also
             # guarded in the server itself.
             max_restarts: 100,
             max_seconds: 10
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

  # Crash reports from any process — ConversationServer, workers, bare Tasks —
  # become Sentry error events. That non-router surface is the whole point:
  # router exceptions already show up in metrics, while a ConversationServer
  # crash mid-provision used to produce a log line and nothing else (#211).
  #
  # Error events only, no structured-log forwarding, and rate-limited so an
  # error loop cannot burn the event quota. Attached only when a DSN is
  # configured, so the default install reports nothing anywhere.
  defp attach_sentry_handler do
    if Application.get_env(:sentry, :dsn) do
      :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
        config: %{
          metadata: [:request_id],
          rate_limiting: [max_events: 20, interval: 60_000]
        }
      })
    end

    :ok
  end
end
