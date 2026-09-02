defmodule Managoat.Runner.Host.LocalTest do
  @moduledoc """
  The reference host: a registration is the calling process, one per runner
  id, gone when that process is.
  """
  use ExUnit.Case, async: true

  alias Managoat.Runner.Host.Local

  test "register, whereis, online and unregister round-trip" do
    id = unique_id()
    meta = %{owner: "me"}

    assert Local.whereis(id) == nil
    assert :ok = Local.register(id, meta)
    assert Local.whereis(id) == self()
    assert {id, meta} in Local.online()

    assert :ok = Local.unregister(id)
    assert Local.whereis(id) == nil
    refute Enum.any?(Local.online(), fn {rid, _} -> rid == id end)
  end

  test "a second registration for the same id is refused" do
    id = unique_id()
    assert :ok = Local.register(id, %{})
    on_exit(fn -> Local.unregister(id) end)

    parent = self()

    spawn_link(fn ->
      send(parent, {:second, Local.register(id, %{})})
    end)

    assert_receive {:second, {:error, :already_registered}}
    assert Local.whereis(id) == self()
  end

  test "a registration goes away with its process" do
    id = unique_id()
    parent = self()

    pid =
      spawn(fn ->
        :ok = Local.register(id, %{})
        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered
    assert Local.whereis(id) == pid

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # The Registry unlinks on the owner's DOWN; give it the one message hop.
    wait_until(fn -> Local.whereis(id) == nil end)
    assert Local.whereis(id) == nil
  end

  test "heartbeat and presence are no-ops" do
    assert :ok = Local.heartbeat(unique_id())
    assert :ok = Local.presence(unique_id(), :online, %{})
    assert :ok = Local.presence(unique_id(), :offline, %{})
  end

  test "child_spec starts the registry the host reads" do
    spec = Local.child_spec([])
    assert {Registry, :start_link, [opts]} = spec.start
    assert opts[:name] == Local.registry()
    assert opts[:keys] == :unique
  end

  defp unique_id, do: "local-#{System.unique_integer([:positive])}"

  defp wait_until(fun, n \\ 100)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, n) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, n - 1)
    end
  end
end
