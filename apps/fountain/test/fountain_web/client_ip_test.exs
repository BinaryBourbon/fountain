defmodule FountainWeb.ClientIpTest do
  @moduledoc """
  Client-IP resolution behind the ingress proxy.

  Every per-IP rate-limit bucket and every audit row keyed on `conn.remote_ip`,
  which behind Traefik is the ingress pod. Production bore this out exactly:
  every recent `audit_events.request_ip` was `10.42.0.0` or `10.42.0.1`, the
  cluster gateway. So "5 registrations per IP per hour" was really "5 per hour,
  globally", and the audit trail attributed everything to the proxy.

  The dangerous half of the fix is the trust list. Stepping over an address that
  is not actually a proxy lets a client put whatever it likes in
  X-Forwarded-For and walk past rate limiting — strictly worse than one shared
  bucket. These cases pin that boundary.
  """

  use ExUnit.Case, async: true

  alias FountainWeb.Endpoint

  defp resolve(headers, peer) do
    conn = Plug.Test.conn(:get, "/")

    %{conn | remote_ip: peer, req_headers: headers}
    |> FountainWeb.Plugs.ClientIp.call([])
    |> Map.fetch!(:remote_ip)
  end

  describe "behind the cluster ingress" do
    test "resolves the client address instead of the proxy" do
      # Traefik forwards from a pod address and records the peer it saw.
      assert resolve([{"x-forwarded-for", "203.0.113.7"}], {10, 42, 0, 1}) ==
               {203, 0, 113, 7}
    end

    test "steps over a chain of cluster hops" do
      assert resolve(
               [{"x-forwarded-for", "203.0.113.7, 10.42.0.5, 10.43.0.2"}],
               {10, 42, 0, 1}
             ) == {203, 0, 113, 7}
    end

    test "falls back to the peer when there is no forwarded header" do
      # If the deployment strips the header, behaviour is exactly as before —
      # this can degrade to the old behaviour but never to something worse.
      assert resolve([], {10, 42, 0, 1}) == {10, 42, 0, 1}
    end

    test "an unparseable header falls back rather than raising" do
      assert resolve([{"x-forwarded-for", "not-an-ip"}], {10, 42, 0, 1}) == {10, 42, 0, 1}
    end
  end

  describe "spoofing" do
    test "a direct client cannot forge its address" do
      # The peer here is a public address, not a configured proxy. Its
      # X-Forwarded-For must be ignored entirely, or rate limiting becomes
      # opt-out.
      assert resolve([{"x-forwarded-for", "1.2.3.4"}], {198, 51, 100, 9}) ==
               {198, 51, 100, 9}
    end

    test "a forged prefix ahead of a real proxy hop is not taken" do
      # Traefik runs with an empty forwardedHeaders.trustedIPs, so it discards
      # client-supplied X-Forwarded-For and writes its own. This pins the
      # behaviour if that ever changes: the rightmost non-proxy address wins,
      # so an injected left-hand entry does not.
      assert resolve(
               [{"x-forwarded-for", "1.2.3.4, 203.0.113.7"}],
               {10, 42, 0, 1}
             ) == {203, 0, 113, 7}
    end
  end

  describe "an IPv4-mapped IPv6 peer (endpoint bound on [::])" do
    # The endpoint listens on [::], so an IPv4 peer arrives as an IPv4-mapped
    # IPv6 tuple — ::ffff:10.42.0.1 — which a v4 CIDR block never matches.
    # Production bore this out: the peer gate failed on every request, the
    # header was never consulted, and buckets keyed on the node gateway again.
    test "a mapped cluster hop is still a trusted proxy" do
      # ::ffff:10.42.0.1
      assert resolve([{"x-forwarded-for", "203.0.113.7"}], {0, 0, 0, 0, 0, 65_535, 2602, 1}) ==
               {203, 0, 113, 7}
    end

    test "the no-header fallback stores the unwrapped v4 address" do
      assert resolve([], {0, 0, 0, 0, 0, 65_535, 2602, 1}) == {10, 42, 0, 1}
    end

    test "a mapped public peer still cannot forge its address" do
      # ::ffff:198.51.100.9 — unwrapping must not widen trust.
      assert resolve(
               [{"x-forwarded-for", "1.2.3.4"}],
               {0, 0, 0, 0, 0, 65_535, 50_739, 25_609}
             ) == {198, 51, 100, 9}
    end
  end

  describe "trusted_proxies/0" do
    test "covers the k3s pod and service networks" do
      proxies = Endpoint.trusted_proxies()

      assert "10.42.0.0/16" in proxies
      assert "10.43.0.0/16" in proxies
    end

    test "does not blanket-trust RFC1918" do
      # LAN clients reach this deployment directly. Trusting 192.168/16 as
      # proxies would step over exactly the addresses being limited.
      proxies = Endpoint.trusted_proxies()

      refute "192.168.0.0/16" in proxies
      refute "172.16.0.0/12" in proxies
      refute "10.0.0.0/8" in proxies
    end
  end
end
