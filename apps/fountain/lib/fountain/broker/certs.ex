defmodule Fountain.Broker.Certs do
  @moduledoc """
  The per-host leaf certificates the proxy presents, cached per replica.

  Signing a leaf is a few milliseconds of ECDSA; a sandbox opens a new
  tunnel per connection, so the same host comes back many times. Leaves
  live thirty days and are re-signed after twenty-nine.
  """
  use GenServer

  alias Fountain.Broker.CA

  @table __MODULE__
  @refresh_after_seconds 29 * 86_400

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The `:ssl` `cert`/`key` options for `host`."
  @spec for_host(String.t()) :: keyword()
  def for_host(host) do
    now = System.system_time(:second)

    case :ets.lookup(@table, host) do
      [{^host, opts, signed_at}] when now - signed_at < @refresh_after_seconds ->
        opts

      _ ->
        opts = CA.leaf(host)
        :ets.insert(@table, {host, opts, now})
        opts
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
