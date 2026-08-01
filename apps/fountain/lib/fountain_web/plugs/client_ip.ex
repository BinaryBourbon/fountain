defmodule FountainWeb.Plugs.ClientIp do
  @moduledoc """
  Resolves the real client address, and records it in `Logger` metadata.

  Every per-IP rate-limit bucket and every audit row keys on `conn.remote_ip`,
  which behind Traefik is the ingress pod — so per-IP limits were really one
  global limit, and the audit trail attributed everything to the proxy.

  ## Why this wraps `RemoteIp` rather than using it directly

  `RemoteIp` walks the forwarding header and returns the rightmost address that
  is not a known proxy. It does not first check whether the *peer* is a proxy,
  so a client connecting directly can simply send its own `X-Forwarded-For` and
  be believed. That turns rate limiting into something a caller opts out of,
  which is worse than the single shared bucket it replaced.

  So the header is consulted only when the connection actually arrived from a
  trusted proxy. A direct connection keeps its peer address no matter what it
  claims.

  Today nothing outside the cluster can reach the application port directly, and
  Traefik runs with an empty `forwardedHeaders.trustedIPs` so it discards
  client-supplied `X-Forwarded-For` and writes its own. Both of those are
  deployment properties that could change without anyone thinking about this
  code, which is exactly why the check belongs here.
  """

  @behaviour Plug

  alias RemoteIp.Block

  @headers ["x-forwarded-for"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = %{conn | remote_ip: resolve(conn)}
    Logger.metadata(remote_ip: format(conn.remote_ip))
    conn
  end

  defp resolve(conn) do
    if from_trusted_proxy?(conn.remote_ip) do
      RemoteIp.from(conn.req_headers, headers: @headers, proxies: proxies()) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  @doc "Whether `ip` is one of the configured proxy addresses."
  def from_trusted_proxy?(ip) when is_tuple(ip) do
    Enum.any?(blocks(), &Block.contains?(&1, Block.encode(ip)))
  end

  def from_trusted_proxy?(_), do: false

  defp blocks do
    Enum.flat_map(proxies(), fn cidr ->
      case Block.parse(cidr) do
        {:ok, block} -> [block]
        _ -> []
      end
    end)
  end

  defp proxies, do: FountainWeb.Endpoint.trusted_proxies()

  defp format(nil), do: "unknown"
  defp format(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp format(other), do: to_string(other)
end
