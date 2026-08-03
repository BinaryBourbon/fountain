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
    conn = %{conn | remote_ip: normalize(conn.remote_ip)}
    conn = %{conn | remote_ip: resolve(conn)}
    Logger.metadata(remote_ip: format(conn.remote_ip))
    conn
  end

  # The endpoint listens on [::] (runtime.exs binds ip: {0,0,0,0,0,0,0,0}), so
  # an IPv4 peer arrives as an IPv4-mapped IPv6 tuple — ::ffff:10.42.0.1 —
  # which RemoteIp.Block never matches against an IPv4 CIDR. Left unwrapped,
  # the peer gate below fails on every request, the forwarded header is never
  # consulted, and every bucket and audit row keys on the node gateway again —
  # the exact regression #216 fixed. Unwrap before any matching or storage.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}

  defp normalize(ip), do: ip

  defp resolve(conn) do
    resolve_address(conn.remote_ip, conn.req_headers)
  end

  @doc """
  The full resolution rule, for callers that hold a peer address and headers
  rather than a `Plug.Conn` — the LiveView mount path in `FountainWeb.Audited`.

  One implementation on purpose: an earlier copy in `Audited` reparsed
  `x-forwarded-for` itself and took the LEFTMOST entry — client-supplied and
  attacker-chosen the moment a proxy hop stops rewriting the header — while
  this path walks from the right and returns the first non-proxy address.
  """
  def resolve_address(peer_ip, headers) do
    if from_trusted_proxy?(peer_ip) do
      RemoteIp.from(headers, headers: @headers, proxies: proxies()) || peer_ip
    else
      peer_ip
    end
  end

  @doc "Whether `ip` is one of the configured proxy addresses."
  def from_trusted_proxy?(ip) when is_tuple(ip) do
    ip = normalize(ip)
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
