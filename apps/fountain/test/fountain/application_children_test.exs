defmodule Fountain.ApplicationChildrenTest do
  @moduledoc """
  The order of the supervision tree, at both ends.

  A `:one_for_one` supervisor starts its children in order and terminates them
  in **reverse**, so one list decides two separate things: what is up before
  the endpoint serves its first request, and what is still up while it drains
  its last.

  The broker listener sat after `FountainWeb.Endpoint` until #1726. That put
  it first in line to stop, so on every rollout the endpoint went on serving —
  and the conversation servers went on reattaching — against a listener that
  had already gone, each one failing with `:listener_down`. The failures
  looked like a startup race and were a shutdown one.

  `async: false`: the broker children exist only when `:broker_listen_port` is
  set, which is application environment.
  """

  use ExUnit.Case, async: false

  describe "children/0 with the broker configured" do
    setup do
      Fountain.BrokerTestHelpers.enable_broker_for([])
      # Port 0 so nothing binds a fixed port; `children/0` only builds specs.
      Application.put_env(:fountain, :broker_listen_port, 0)
      :ok
    end

    test "the listener starts before the endpoint, so it stops after it" do
      ids = ids()

      assert before?(ids, Managoat.Broker, FountainWeb.Endpoint)
    end

    test "the listener starts before the conversation supervisor, so it outlives it" do
      # This is the half that matters most in practice: most :listener_down
      # events are `reattach|failed`, raised by a ConversationServer under
      # Fountain.ConversationSupervisor rather than by an inbound request.
      ids = ids()

      assert before?(ids, Managoat.Broker, Horde.DynamicSupervisor)
    end

    test "the request-log writer starts before the listener" do
      # A row cast at the first proxied request must find a writer.
      ids = ids()

      assert before?(ids, Fountain.Broker.Native.RequestLog, Managoat.Broker)
    end

    test "the repo starts before the broker, which is all the broker needs" do
      ids = ids()

      assert before?(ids, Fountain.Repo, Fountain.Broker.Native.RequestLog)
    end

    test "the endpoint is last" do
      assert List.last(ids()) == FountainWeb.Endpoint
    end
  end

  describe "children/0 with the broker off" do
    test "carries no broker children at all" do
      refute Fountain.Broker.configured?()

      ids = ids()

      refute Managoat.Broker in ids
      refute Fountain.Broker.Native.RequestLog in ids
    end

    test "still ends with the endpoint" do
      assert List.last(ids()) == FountainWeb.Endpoint
    end
  end

  defp ids, do: Enum.map(Fountain.Application.children(), &id/1)

  defp id({module, _opts}), do: module
  defp id(module) when is_atom(module), do: module

  defp before?(ids, earlier, later) do
    assert earlier in ids, "#{inspect(earlier)} is not in the supervision tree"
    assert later in ids, "#{inspect(later)} is not in the supervision tree"

    Enum.find_index(ids, &(&1 == earlier)) < Enum.find_index(ids, &(&1 == later))
  end
end
