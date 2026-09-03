defmodule Fountain.BrokerTestHelpers do
  @moduledoc """
  Put the egress broker "on" for a user in a test, and restore the app env
  after. Global state, so the test module that uses it is `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @keys [:broker_listen_port, :broker_proxy_url, :broker_tenants]

  def enable_broker_for(user_ids) when is_list(user_ids) do
    previous = for k <- @keys, do: {k, Application.get_env(:fountain, k)}

    on_exit(fn ->
      for {k, v} <- previous do
        if is_nil(v),
          do: Application.delete_env(:fountain, k),
          else: Application.put_env(:fountain, k, v)
      end
    end)

    # A port, not a listener: `Broker.backend/0` reads the config, and a test
    # that only needs the ratchet on does not need anything bound.
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :broker_tenants, user_ids)
    :ok
  end
end
