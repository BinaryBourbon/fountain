defmodule FountainWeb.MetricsTest do
  @moduledoc """
  Cover for the Prometheus scrape surface.

  Two things worth pinning. The reporter rejects `summary/2`, which every metric
  in `metrics/0` uses, so `prometheus_metrics/0` has to stay a separate list —
  wiring the wrong one up raises at boot, in production, after a deploy.

  And route tags must come from the matched route pattern rather than the
  request path, or every conversation id mints a new time series and the
  cardinality quietly eats Prometheus.
  """

  use FountainWeb.ConnCase, async: false

  alias FountainWeb.MetricsPlug
  # Aliased to avoid shadowing Telemetry.Metrics.* struct names below.
  alias FountainWeb.Telemetry, as: AppTelemetry

  defp scrape do
    conn = MetricsPlug.call(Plug.Test.conn(:get, "/metrics"), [])
    {conn.status, conn.resp_body}
  end

  describe "MetricsPlug" do
    test "serves the scrape payload on /metrics" do
      {status, body} = scrape()

      assert status == 200
      assert is_binary(body)
    end

    test "answers /health without a full scrape" do
      conn = MetricsPlug.call(Plug.Test.conn(:get, "/health"), [])

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "404s anything else, so the port exposes nothing incidental" do
      conn = MetricsPlug.call(Plug.Test.conn(:get, "/"), [])
      assert conn.status == 404

      conn = MetricsPlug.call(Plug.Test.conn(:get, "/api/agents"), [])
      assert conn.status == 404
    end
  end

  describe "prometheus_metrics/0" do
    test "uses no summary metrics — the reporter cannot represent them" do
      for metric <- AppTelemetry.prometheus_metrics() do
        refute metric.__struct__ == Telemetry.Metrics.Summary,
               "#{inspect(metric.name)} is a summary; " <>
                 "TelemetryMetricsPrometheus.Core raises on those at boot"
      end
    end

    test "every metric is a type the reporter implements" do
      allowed = [
        Telemetry.Metrics.Counter,
        Telemetry.Metrics.Distribution,
        Telemetry.Metrics.LastValue,
        Telemetry.Metrics.Sum
      ]

      for metric <- AppTelemetry.prometheus_metrics() do
        assert metric.__struct__ in allowed,
               "#{inspect(metric.name)} is #{inspect(metric.__struct__)}"
      end
    end

    test "covers the signals an operator needs at 3am" do
      names = Enum.map(AppTelemetry.prometheus_metrics(), & &1.name)

      # Request rate/latency/errors, DB pool saturation, and the domain events
      # that cost money.
      assert [:phoenix, :router_dispatch, :stop, :duration] in names
      assert [:phoenix, :router_dispatch, :exception, :count] in names
      assert [:fountain, :repo, :query, :queue_time] in names
      assert [:fountain, :stage, :count] in names
      assert [:fountain, :fresh_provision, :stop, :duration] in names
    end

    test "every subscribed fountain event has a live producer" do
      # The class of bug behind #310: metrics subscribed to event names that
      # nothing emits, passing every name-list assertion while the scrape
      # stays empty forever. Pin each custom event to the code that fires it.
      emitted = [
        # Conversations.publish_stage/4
        [:fountain, :stage],
        # Fountain.Telemetry.span/3 callers
        [:fountain, :fresh_provision, :stop],
        [:fountain, :reattach, :stop],
        # :telemetry.execute call sites
        [:fountain, :sandbox, :reclaimed],
        [:fountain, :reaper, :run],
        [:fountain, :reaper, :untracked],
        # Fountain.OpsGauges.emit_telemetry/0 (#321) — exercised directly by
        # Fountain.OpsGaugesTest since the poller is off in test
        [:fountain, :conversations],
        [:fountain, :sandboxes],
        [:fountain, :oban_queue],
        # Emitted by Oban itself around every job execution
        [:oban, :job, :stop],
        [:oban, :job, :exception],
        # Library-emitted
        [:phoenix, :router_dispatch, :stop],
        [:phoenix, :router_dispatch, :exception],
        [:fountain, :repo, :query],
        [:fountain, :funnel],
        [:vm, :memory],
        [:vm, :total_run_queue_lengths]
      ]

      for metric <- AppTelemetry.prometheus_metrics() do
        assert metric.event_name in emitted,
               "#{inspect(metric.name)} subscribes to #{inspect(metric.event_name)}, " <>
                 "which no known code path emits — this is how #310 happened"
      end
    end
  end

  describe "end to end" do
    test "a real request lands in the scrape output", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)

      conn |> authed_with_key(key) |> get("/api/agents") |> json_response(200)

      # The reporter aggregates synchronously on the telemetry event, but give
      # the handler a moment before scraping.
      Process.sleep(50)
      {200, body} = scrape()

      assert body =~ "phoenix_router_dispatch_stop_duration"
    end

    test "a stage event lands in the scrape with stage and status labels" do
      # The subscription side of the stage counter. The producer side —
      # ConversationServer actually publishing these stages — is asserted in
      # conversation_server_test.exs against a real provision.
      Fountain.Telemetry.event(
        [:stage],
        %{stage: "provision", status: "failed", conv_id: Ecto.UUID.generate()},
        %{count: 1}
      )

      Process.sleep(50)
      {200, body} = scrape()

      assert Regex.match?(
               ~r/fountain_stage_count\{[^}]*stage="provision"[^}]*status="failed"[^}]*\}/,
               body
             )

      # conv_id is metadata, never a label — one series per conversation
      # would eat Prometheus.
      refute body =~ "conv_id="
    end

    test "ops gauges and Oban events land in the scrape (#321)" do
      :telemetry.execute([:fountain, :conversations], %{count: 3}, %{status: "idle"})
      :telemetry.execute([:fountain, :oban_queue], %{depth: 2}, %{
        queue: "maintenance",
        state: "available"
      })

      job = %Oban.Job{queue: "maintenance", worker: "Fountain.Workers.SandboxReaper"}
      :telemetry.execute([:oban, :job, :stop], %{duration: 1_000}, %{job: job, state: :success})

      :telemetry.execute([:oban, :job, :exception], %{duration: 1_000}, %{
        job: job,
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        stacktrace: []
      })

      Process.sleep(50)
      {200, body} = scrape()

      assert Regex.match?(~r/fountain_conversations_count\{[^}]*status="idle"[^}]*\} 3/, body)

      assert Regex.match?(
               ~r/fountain_oban_queue_depth\{[^}]*queue="maintenance"[^}]*state="available"[^}]*\} 2/,
               body
             )

      assert Regex.match?(
               ~r/fountain_oban_job_stop_count\{[^}]*queue="maintenance"[^}]*state="success"[^}]*\}/,
               body
             )

      assert Regex.match?(
               ~r/fountain_oban_job_exception_count\{[^}]*worker="Fountain.Workers.SandboxReaper"[^}]*\}/,
               body
             )
    end

    test "route tags are the matched pattern, not the raw path", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)
      conv = insert_conversation(user_id: user.id)

      conn |> authed_with_key(key) |> get("/api/conversations/#{conv.id}")

      Process.sleep(50)
      {200, body} = scrape()

      # The conversation id must not appear as a label value; if it does, every
      # conversation is its own time series.
      refute body =~ conv.id
    end
  end
end
