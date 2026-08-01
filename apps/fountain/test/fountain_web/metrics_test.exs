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
      assert [:fountain, :provision, :exception, :count] in names
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
