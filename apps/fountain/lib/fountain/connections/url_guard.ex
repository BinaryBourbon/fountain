defmodule Fountain.Connections.UrlGuard do
  @moduledoc """
  The one rule for a URL a tenant hands Fountain to fetch server-side
  (#1186): `https`, a real hostname, and nothing that resolves into the
  cluster. The OAuth client, MCP discovery and dynamic client registration
  all `GET`/`POST` tenant-supplied addresses from inside the platform, which
  is exactly the request an SSRF wants — so every one of them passes through
  `check/1` first, and again on each use, since DNS can change between a
  save and a fetch.

  Rejected: any scheme but `https`, an IP literal, `localhost` and the
  cluster-internal names, and a hostname that resolves only to loopback,
  private (RFC 1918), link-local, CGNAT or the metadata range. A hostname
  that does not resolve is also refused: nothing could be fetched from it,
  and a name that resolves later to something private is the trick.

  `:connections_allow_private_hosts` (test only) turns the resolution check
  off so a stub can stand in for a provider.
  """

  @internal_hosts ~w(localhost localhost.localdomain internal kubernetes kubernetes.default metadata.google.internal metadata.google instance-data)

  @type reason ::
          :not_https | :no_host | :ip_literal | :internal_host | :private_address | :unresolvable

  @doc "`:ok`, or `{:error, reason}` naming the rule the URL broke."
  @spec check(String.t() | nil) :: :ok | {:error, reason()}
  def check(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        check_host(String.downcase(host))

      %URI{scheme: "https"} ->
        {:error, :no_host}

      _ ->
        {:error, :not_https}
    end
  end

  def check(_), do: {:error, :not_https}

  @doc "The rule as a changeset validation on a URL field. Blank passes; `validate_required` owns that."
  def validate(changeset, field) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, url ->
      case check(url) do
        :ok -> []
        {:error, reason} -> [{field, message(reason)}]
      end
    end)
  end

  @doc "Why a URL was refused, for a form or an API error."
  def message(:not_https), do: "must be an https URL"
  def message(:no_host), do: "must name a host"
  def message(:ip_literal), do: "must be a hostname, not an IP address"
  def message(:internal_host), do: "must not be an internal host"
  def message(:private_address), do: "must not resolve to a private address"
  def message(:unresolvable), do: "does not resolve"

  defp check_host(host) do
    cond do
      host in @internal_hosts or String.ends_with?(host, ".internal") or
          String.ends_with?(host, ".local") ->
        {:error, :internal_host}

      ip_literal?(host) ->
        {:error, :ip_literal}

      allow_private?() ->
        :ok

      true ->
        resolve(host)
    end
  end

  defp ip_literal?(host) do
    host = String.trim(host, "[") |> String.trim("]")
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    addrs =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, addrs} -> addrs
          _ -> []
        end
      end)

    cond do
      addrs == [] -> {:error, :unresolvable}
      Enum.any?(addrs, &private?/1) -> {:error, :private_address}
      true -> :ok
    end
  end

  # IPv4: loopback, RFC 1918, link-local, CGNAT, the metadata service, 0/8.
  defp private?({0, _, _, _}), do: true
  defp private?({10, _, _, _}), do: true
  defp private?({127, _, _, _}), do: true
  defp private?({169, 254, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?({100, b, _, _}) when b in 64..127, do: true
  # IPv6: loopback, unspecified, ULA, link-local, and v4-mapped of the above.
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true

  defp private?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: private?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp private?(_), do: false

  defp allow_private?, do: Application.get_env(:fountain, :connections_allow_private_hosts, false)
end
