defmodule Fountain.Broker.Supervisor do
  @moduledoc """
  The broker's process tree: the leaf-certificate cache and the proxy
  listener. Started by the application only when `BROKER_LISTEN_PORT` is
  set; off, nothing here runs and nothing listens.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      Fountain.Broker.Certs,
      Fountain.Broker.Proxy.listener_spec(opts)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
