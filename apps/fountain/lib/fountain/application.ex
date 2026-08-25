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

    # Counts metering events this node drops, for /admin/finance (#1038).
    Fountain.Billing.Reconciliation.attach_drop_counter()

    cluster_topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        FountainWeb.Telemetry,
        Fountain.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:fountain, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:fountain, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Fountain.PubSub},
        # Fire-and-forget work started from a request and never awaited: the
        # `last_used_at` stamp on an API key, the password-reset email. These
        # used to be `Task.async`, which *links* to the caller — so a transient
        # failure in a write nobody wants the result of could take down the
        # request process that started it, or the test that made the request
        # (#1040). Supervised and unlinked, a crash here is a log line.
        {Task.Supervisor, name: Fountain.TaskSupervisor},
        FountainWeb.Plugs.RateLimit.Sweeper,
        Fountain.Conversations.Redaction,
        Fountain.FeatureFlags.Cache,
        Fountain.Analytics.Sink,
        Fountain.Team.Comms.Inbound.Seen,
        {Oban, Application.fetch_env!(:fountain, Oban)}
      ] ++
        cluster_children(cluster_topologies) ++
        [
          # Horde.Registry + Horde.DynamicSupervisor are CRDT-backed
          # cluster-aware replacements. Single-node behavior is
          # unchanged; on multiple nodes they sync state and let
          # processes be addressed across the cluster.
          {Horde.Registry, [name: Fountain.ConversationRegistry, keys: :unique, members: :auto]},
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
          # Hosted buzz-acp harnesses (ADR 0020, gate #736). Same Horde shape as
          # the conversation tree: one harness per Buzz identity, addressable
          # cluster-wide, surviving node loss. The BootSweep stands the enabled
          # ones up after both are ready, and is inert until a `buzz-acp` binary
          # path is configured (increment 2b), so this adds nothing at runtime on
          # an instance that has not opted in.
          {Horde.Registry, [name: Fountain.BuzzRegistry, keys: :unique, members: :auto]},
          # Self-hosted runner sockets (ADR 0022): a `fountain runner` daemon
          # dials in and its connection process registers here under the
          # runner id, so `Fountain.Sandbox.Runner` on any node can reach it.
          {Horde.Registry, [name: Fountain.RunnerRegistry, keys: :unique, members: :auto]},
          {Horde.DynamicSupervisor,
           [
             name: Fountain.BuzzSupervisor,
             strategy: :one_for_one,
             distribution_strategy: Horde.UniformDistribution,
             members: :auto,
             max_restarts: 100,
             max_seconds: 10
           ]},
          Fountain.Buzz.BootSweep,
          FountainWeb.Endpoint
        ] ++ broker_children()

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

  # The egress proxy (ADR 0019) listens only when BROKER_LISTEN_PORT is set;
  # off, no process here exists.
  defp broker_children do
    case Application.get_env(:fountain, :broker_listen_port) do
      port when is_integer(port) -> [{Fountain.Broker.Supervisor, port: port}]
      _ -> []
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

  # Migrations run at boot in a release and nowhere else — dev and test manage
  # their own schema through mix, and RELEASE_NAME is how a release announces
  # itself.
  #
  # MIGRATE_ON_BOOT=false opts a release out (#610), for the deployment that
  # runs migrations once in a Job and lets its pods only serve. This gate and
  # the image's CMD (`Fountain.Release.migrate_on_boot/0`) read the one
  # switch, so turning it off leaves no path here that migrates — the switch
  # would be a decoration if it closed only one of the two.
  #
  # Public for the test that pins that pairing; not part of the app's API.
  @doc false
  def skip_migrations? do
    System.get_env("RELEASE_NAME") == nil or not Fountain.Release.migrate_on_boot?()
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
