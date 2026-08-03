defmodule FountainWeb.Telemetry do
  @moduledoc false
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
        {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}
      ] ++ metrics_server()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Metrics are served on their own port, never through the Phoenix endpoint.
  # The Traefik IngressRoute matches on Host with no path predicate, so anything
  # mounted on the endpoint is public — including request rates, route names and
  # DB timings. The scrape port is reachable only from inside the cluster.
  #
  # nil port disables the server entirely, which is the default in dev and test
  # so a stray listener can't collide with concurrent runs.
  defp metrics_server do
    case Application.get_env(:fountain, :metrics_port) do
      nil -> []
      port -> [{Bandit, plug: FountainWeb.MetricsPlug, scheme: :http, port: port}]
    end
  end

  @doc """
  Metrics exported to Prometheus.

  Deliberately a separate list from `metrics/0`. That one is built for
  LiveDashboard and is all `summary/2`, which the Prometheus core reporter does
  not implement — wiring it up directly raises at boot. Prometheus wants
  `distribution` (histogram), `counter`, `sum` and `last_value`.

  Bucket boundaries are in milliseconds and chosen around what matters here:
  sub-100ms is a healthy page render, and the tail past 1s is what a user
  actually notices.
  """
  def prometheus_metrics do
    [
      # ── HTTP ──────────────────────────────────────────────────────────────
      distribution("phoenix.router_dispatch.stop.duration",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:route, :method, :status],
        tag_values: &http_tags/1,
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]],
        description: "HTTP request duration by route, method and status"
      ),
      counter("phoenix.router_dispatch.stop.count",
        event_name: [:phoenix, :router_dispatch, :stop],
        tags: [:route, :method, :status],
        tag_values: &http_tags/1,
        description: "HTTP requests by route, method and status"
      ),
      # Exceptions that escape the router. This is the closest thing to an
      # error-rate signal until real error tracking lands.
      counter("phoenix.router_dispatch.exception.count",
        event_name: [:phoenix, :router_dispatch, :exception],
        tags: [:route, :kind],
        tag_values: &exception_tags/1,
        description: "Unhandled exceptions by route"
      ),

      # ── Database ──────────────────────────────────────────────────────────
      distribution("fountain.repo.query.total_time",
        event_name: [:fountain, :repo, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]],
        description: "Ecto query duration"
      ),
      # Queue time is the pool-saturation signal: it climbs when every
      # connection is checked out, which is the failure that looks like "the
      # whole app got slow" rather than "one query got slow".
      distribution("fountain.repo.query.queue_time",
        event_name: [:fountain, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 500]],
        description: "Time waiting for a database connection from the pool"
      ),

      # ── Conversations ─────────────────────────────────────────────────────
      # These are the domain events that cost money and wake people up.
      #
      # The counter hangs off the [:fountain, :stage] event that
      # Conversations.publish_stage/4 emits — the same funnel that feeds the
      # client-visible stage stream. Provision/reattach/turn failures are
      # handled inside the GenServer (rescued, mapped to "failed" stages), so
      # a span :exception event never fires for them; counting stages is the
      # only wiring that sees every outcome. Tags are bounded: stage is a
      # fixed set of pipeline step names, status is
      # started/done/failed/interrupted.
      counter("fountain.stage.count",
        event_name: [:fountain, :stage],
        tags: [:stage, :status],
        description: "Conversation stage transitions by stage and status"
      ),
      distribution("fountain.fresh_provision.stop.duration",
        event_name: [:fountain, :fresh_provision, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long a fresh sandbox takes to provision"
      ),
      distribution("fountain.reattach.stop.duration",
        event_name: [:fountain, :reattach, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1000, 5000, 10_000, 30_000, 60_000, 120_000]],
        description: "How long a sandbox reattach takes"
      ),

      # ── Lifecycle sweeps ──────────────────────────────────────────────────
      counter("fountain.sandbox.reclaimed.count",
        event_name: [:fountain, :sandbox, :reclaimed],
        description: "Sandboxes reclaimed by the lifecycle bounds"
      ),
      sum("fountain.reaper.run.released",
        event_name: [:fountain, :reaper, :run],
        measurement: :released,
        description: "Sprites released by SandboxReaper runs"
      ),
      sum("fountain.reaper.run.expired",
        event_name: [:fountain, :reaper, :run],
        measurement: :expired,
        description: "Sandbox rows expired by SandboxReaper runs"
      ),
      sum("fountain.reaper.untracked.count",
        event_name: [:fountain, :reaper, :untracked],
        measurement: :count,
        description: "Untracked sprites found running with no live sandbox row"
      ),

      # ── Lifecycle funnel (#282) ───────────────────────────────────────────
      # Gauges polled from Fountain.Funnel.emit_telemetry/0 so Grafana can
      # trend stage counts and conversion over time.
      last_value("fountain.funnel.registered",
        event_name: [:fountain, :funnel],
        measurement: :registered,
        description: "Users registered (all time)"
      ),
      last_value("fountain.funnel.verified",
        event_name: [:fountain, :funnel],
        measurement: :verified,
        description: "Users with a verified email"
      ),
      last_value("fountain.funnel.onboarded",
        event_name: [:fountain, :funnel],
        measurement: :onboarded,
        description: "Users who completed onboarding"
      ),
      last_value("fountain.funnel.activated",
        event_name: [:fountain, :funnel],
        measurement: :activated,
        description: "Users with at least one conversation"
      ),
      last_value("fountain.funnel.subscribed",
        event_name: [:fountain, :funnel],
        measurement: :subscribed,
        description: "Users with an active or past_due subscription"
      ),
      last_value("fountain.funnel.stalled_verified",
        event_name: [:fountain, :funnel],
        measurement: :stalled_verified,
        description: "Verified users who never started a conversation"
      ),

      # ── Ops gauges (#321) ─────────────────────────────────────────────────
      # Polled from Fountain.OpsGauges.emit_telemetry/0; zeros emitted for
      # every known status so the series exist from boot.
      last_value("fountain.conversations.count",
        event_name: [:fountain, :conversations],
        measurement: :count,
        tags: [:status],
        description: "Conversations by status"
      ),
      last_value("fountain.sandboxes.count",
        event_name: [:fountain, :sandboxes],
        measurement: :count,
        tags: [:status],
        description: "Sandbox rows by status"
      ),
      last_value("fountain.oban_queue.depth",
        event_name: [:fountain, :oban_queue],
        measurement: :depth,
        tags: [:queue, :state],
        description: "Oban jobs by queue and state (non-terminal states + discarded)"
      ),

      # ── Oban job outcomes (#321) ──────────────────────────────────────────
      # Oban catches job exceptions internally and reports them only via
      # telemetry, so neither the Sentry LoggerHandler nor any crash report
      # reliably sees a failing RetentionPruner or SandboxReaper. These hang
      # directly off Oban's own events — no poller involved.
      counter("fountain.oban_job.stop.count",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        tags: [:queue, :state],
        tag_values: &oban_job_tags/1,
        description: "Completed Oban job executions by queue and result state"
      ),
      counter("fountain.oban_job.exception.count",
        event_name: [:oban, :job, :exception],
        measurement: :duration,
        tags: [:queue, :worker],
        tag_values: &oban_job_tags/1,
        description: "Oban job executions that raised, by queue and worker"
      ),

      # ── VM ────────────────────────────────────────────────────────────────
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  # Route is unbounded if taken from the raw path (every conversation id would
  # mint a new time series), so use the matched route pattern instead.
  defp http_tags(meta) do
    %{
      route: meta[:route] || "unmatched",
      method: meta[:conn] && meta.conn.method,
      status: meta[:conn] && meta.conn.status
    }
  end

  defp exception_tags(meta) do
    %{route: meta[:route] || "unmatched", kind: meta[:kind]}
  end

  # Worker cardinality is bounded by the workers defined in this repo; the
  # queue set by config. `state` is present on :stop (:success, :failure,
  # :snoozed, …) and absent on :exception, where the worker is the signal.
  defp oban_job_tags(meta) do
    %{
      queue: meta.job.queue,
      worker: meta.job.worker,
      state: Map.get(meta, :state, "exception")
    }
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("fountain.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("fountain.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("fountain.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("fountain.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("fountain.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    # Funnel stage gauges (#282) and ops gauges (#321). Full-table passes
    # every tick — cheap at current scale. Off in test: the poller's Repo
    # calls would race the SQL Sandbox's connection ownership (the modules
    # are exercised directly by tests instead).
    if Application.get_env(:fountain, :funnel_poller_enabled, true) do
      [
        {Fountain.Funnel, :emit_telemetry, []},
        {Fountain.OpsGauges, :emit_telemetry, []}
      ]
    else
      []
    end
  end
end
