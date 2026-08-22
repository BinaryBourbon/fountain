defmodule Fountain.Webhooks.Url do
  @moduledoc """
  The SSRF guard on a tenant-controlled URL that Fountain requests from
  inside the cluster.

  Three separate defences, because each one alone is defeated by an obvious
  trick:

  1. **Shape** (`validate/1`) — `https://` only (a config flag permits
     `http://` for self-host and dev), a real host, no credentials in the
     URL. Checked when the endpoint is saved, so a typo fails in the form.
  2. **Address** (`resolve/1`) — every A and AAAA record the host resolves to
     must be publicly routable. Checked **at request time**, not only at
     create time: `webhook.example.com` may answer `93.184.216.34` when the
     form is submitted and `169.254.169.254` a minute later, and a create-time
     check alone is decorative against that.
  3. **Pinning** (`pin/1`) — the request goes to the address that was
     checked, with the original hostname carried in the `Host` header and in
     TLS SNI. Without this there is still a window between our resolution and
     the HTTP client's own, which is the whole of a DNS rebinding attack.

  Redirects are not followed anywhere in the delivery path. A `302` to
  `169.254.169.254` walks past all three of the above, so the worker treats a
  redirect as a delivery failure rather than as something to chase.

  Blocked ranges are the ones that are *not* somebody else's public server:
  loopback, link-local (which is where every cloud metadata service lives),
  RFC1918, carrier-grade NAT, the IETF protocol and documentation blocks,
  multicast and reserved space. IPv6 gets the same treatment, plus the two
  transition encodings (`::ffff:a.b.c.d` and `2002::/16`) that would otherwise
  smuggle an IPv4 address past an IPv6 check.
  """

  import Bitwise, only: [band: 2]

  @doc "Whether this instance permits plain `http://` endpoint URLs."
  @spec allow_http?() :: boolean()
  def allow_http?, do: Application.get_env(:fountain, :webhook_allow_http, false)

  @doc """
  Check the shape of a URL. Returns the parsed `URI` or a human-readable
  reason the form can show.
  """
  @spec validate(term()) :: {:ok, URI.t()} | {:error, String.t()}
  def validate(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme == "http" and not allow_http?() ->
        {:error, "must use https"}

      uri.scheme not in ["http", "https"] ->
        {:error, "must use https"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "must include a host"}

      uri.userinfo != nil ->
        {:error, "must not carry credentials in the URL"}

      String.length(url) > 2000 ->
        {:error, "is too long"}

      true ->
        case classify_host(uri.host) do
          :ok -> {:ok, uri}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate(_), do: {:error, "must be a URL"}

  # A literal address in the URL is checked here as well as at request time —
  # `http://127.0.0.1/hook` should never be storable in the first place.
  defp classify_host(host) do
    case parse_address(host) do
      {:ok, addr} -> check_address(addr)
      :error -> :ok
    end
  end

  @doc """
  Resolve `host` and check every address it answers with.

  Returns the addresses in preference order (IPv4 first, matching what an
  HTTP client picks by default here). `{:error, reason}` when the host does
  not resolve or when **any** answer is a blocked target — any, not all,
  because a host that returns one public and one private address is a
  rebinding attack with the round-robin done for it.
  """
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, String.t()}
  def resolve(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    v4 = getaddrs(charlist, :inet)
    v6 = getaddrs(charlist, :inet6)

    case v4 ++ v6 do
      [] ->
        {:error, "does not resolve"}

      addrs ->
        case Enum.find_value(addrs, fn addr ->
               case check_address(addr) do
                 :ok -> nil
                 {:error, reason} -> reason
               end
             end) do
          nil -> {:ok, addrs}
          reason -> {:error, reason}
        end
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

  @doc """
  The check the form runs: shape, plus the address the host resolves to
  *right now*.

  A host that does not resolve at all is allowed through. A receiver that is
  not deployed yet is an ordinary thing to save, and the request-time check in
  `pin/1` is the authoritative one either way. A host that resolves somewhere
  private is refused here, so `http://localhost/hook` fails in the form rather
  than silently failing every delivery.
  """
  @spec check_saveable(term()) :: {:ok, URI.t()} | {:error, String.t()}
  def check_saveable(url) do
    with {:ok, uri} <- validate(url) do
      case resolve(uri.host) do
        {:ok, _addresses} -> {:ok, uri}
        {:error, "does not resolve"} -> {:ok, uri}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Everything the delivery worker needs to make one checked request.

  Returns `{:ok, %{url: pinned_url, host: original_host, address: addr}}`,
  where `pinned_url` addresses the resolved IP directly. The caller sends the
  original host as the `Host` header and as the TLS server name, so the
  request is indistinguishable to the receiver from an unpinned one, and
  indistinguishable to an attacker from one that cannot be rebound.
  """
  @spec pin(String.t()) ::
          {:ok, %{url: String.t(), host: String.t(), address: :inet.ip_address()}}
          | {:error, String.t()}
  def pin(url) when is_binary(url) do
    with {:ok, uri} <- validate(url),
         {:ok, [address | _]} <- resolve(uri.host) do
      {:ok,
       %{
         url: URI.to_string(%{uri | host: literal(address)}),
         host: uri.host,
         address: address
       }}
    end
  end

  # An IPv6 literal has to be bracketed in a URL; `URI.to_string/1` does not
  # do it for us.
  defp literal(address) do
    case :inet.ntoa(address) do
      {:error, _} -> raise ArgumentError, "unrenderable address"
      chars -> to_string(chars) |> bracket()
    end
  end

  defp bracket(str) do
    if String.contains?(str, ":"), do: "[" <> str <> "]", else: str
  end

  defp parse_address(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :error
    end
  end

  @doc """
  Whether an address is a target a tenant may point us at.

  Public so the tests can enumerate the ranges directly rather than only
  through a URL.
  """
  @spec check_address(:inet.ip_address()) :: :ok | {:error, String.t()}
  # IPv4-mapped and 6to4 carry an IPv4 address inside an IPv6 one. Unwrap
  # before judging, or `::ffff:169.254.169.254` sails through as "some v6
  # address we have no rule about".
  def check_address({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    check_address({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  def check_address({0x2002, ab, cd, _, _, _, _, _}) do
    check_address({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  def check_address({a, b, c, _d} = addr) do
    cond do
      a == 0 -> blocked(addr, "unspecified")
      a == 10 -> blocked(addr, "a private network")
      a == 127 -> blocked(addr, "loopback")
      a == 100 and b in 64..127 -> blocked(addr, "carrier-grade NAT space")
      a == 169 and b == 254 -> blocked(addr, "link-local (cloud metadata)")
      a == 172 and b in 16..31 -> blocked(addr, "a private network")
      a == 192 and b == 0 and c == 0 -> blocked(addr, "IETF protocol space")
      a == 192 and b == 0 and c == 2 -> blocked(addr, "documentation space")
      a == 192 and b == 88 and c == 99 -> blocked(addr, "6to4 relay anycast")
      a == 192 and b == 168 -> blocked(addr, "a private network")
      a == 198 and b in 18..19 -> blocked(addr, "benchmark space")
      a == 198 and b == 51 and c == 100 -> blocked(addr, "documentation space")
      a == 203 and b == 0 and c == 113 -> blocked(addr, "documentation space")
      a >= 224 -> blocked(addr, "multicast or reserved space")
      true -> :ok
    end
  end

  def check_address({a, b, _, _, _, _, _, _} = addr) do
    cond do
      addr == {0, 0, 0, 0, 0, 0, 0, 0} -> blocked(addr, "unspecified")
      addr == {0, 0, 0, 0, 0, 0, 0, 1} -> blocked(addr, "loopback")
      # NAT64 (64:ff9b::/96) wraps an IPv4 address the same way ::ffff: does.
      a == 0x64 and b == 0xFF9B -> blocked(addr, "NAT64 space")
      band(a, 0xFE00) == 0xFC00 -> blocked(addr, "a private network")
      band(a, 0xFFC0) == 0xFE80 -> blocked(addr, "link-local")
      band(a, 0xFF00) == 0xFF00 -> blocked(addr, "multicast")
      true -> :ok
    end
  end

  defp blocked(addr, what) do
    {:error, "resolves to #{:inet.ntoa(addr)}, which is #{what}"}
  end
end
