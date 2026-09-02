defmodule Managoat.Broker.Certs do
  @moduledoc """
  One listener's certificates: the derived root, and the per-host leaves
  the proxy presents, cached in an ETS table.

  Signing a leaf is a few milliseconds of ECDSA; a sandbox opens a new
  tunnel per connection, so the same host comes back many times. Leaves
  live thirty days and are re-signed after twenty-nine.

  The table is created by the listener's supervisor (`Managoat.Broker`), so
  it lives exactly as long as the listener, and handed to every connection
  handler as an option. Public, so the handlers read and insert without a
  round trip through a process.
  """

  alias Managoat.Broker.CA

  @refresh_after_seconds 29 * 86_400

  @opaque t :: :ets.table()

  @doc "A table holding the root derived from `seed`. Owned by the caller."
  @spec new(binary()) :: t()
  def new(seed) do
    table = :ets.new(__MODULE__, [:public, :set, read_concurrency: true])
    :ets.insert(table, {:root, CA.root(seed)})
    table
  end

  @doc "The root certificate and key."
  @spec root(t()) :: CA.root()
  def root(table) do
    [{:root, pair}] = :ets.lookup(table, :root)
    pair
  end

  @doc "The root certificate as PEM."
  @spec ca_pem(t()) :: String.t()
  def ca_pem(table), do: table |> root() |> elem(0) |> X509.Certificate.to_pem()

  @doc "The root certificate as DER."
  @spec ca_der(t()) :: binary()
  def ca_der(table), do: table |> root() |> elem(0) |> X509.Certificate.to_der()

  @doc "The `:ssl` `cert`/`key` options for `host`, signed by the root."
  @spec for_host(t(), String.t()) :: keyword()
  def for_host(table, host) do
    now = System.system_time(:second)

    case :ets.lookup(table, {:leaf, host}) do
      [{{:leaf, ^host}, opts, signed_at}] when now - signed_at < @refresh_after_seconds ->
        opts

      _ ->
        opts = CA.leaf(host, root(table))
        :ets.insert(table, {{:leaf, host}, opts, now})
        opts
    end
  end
end
