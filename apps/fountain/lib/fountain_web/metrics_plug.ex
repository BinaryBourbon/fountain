defmodule FountainWeb.MetricsPlug do
  @moduledoc """
  Serves the Prometheus scrape endpoint on its own port.

  Deliberately not mounted on `FountainWeb.Endpoint`. The Traefik IngressRoute
  matches on `Host` with no path predicate, so every path on the endpoint is
  publicly reachable — and this response enumerates routes, request rates,
  database timings and VM internals. Running it on a separate port that the
  Service exposes but the IngressRoute does not means it is reachable from
  Prometheus inside the cluster and from nowhere else.

  No auth: the port is not routable from outside, and adding a shared secret
  would mostly be a second thing to get wrong. If the scrape port is ever
  exposed through an ingress, that assumption breaks and this needs auth.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/metrics"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape())
  end

  # A liveness path on the metrics port, so a probe can distinguish "the metrics
  # server is up" from "the app is up" without scraping the whole payload.
  def call(%Plug.Conn{request_path: "/health"} = conn, _opts) do
    send_resp(conn, 200, "ok")
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")
end
