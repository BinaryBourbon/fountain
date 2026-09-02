defmodule Managoat.Broker.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Managoat.Broker.{Session, Store}
  alias Managoat.Broker.Store.Memory

  setup do
    name = :"memory_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Memory, name: name}, id: name))
    %{store: name}
  end

  test "put, lookup, delete", %{store: store} do
    token = Memory.generate_token()
    assert String.starts_with?(token, "mb_")
    session = %Session{meta: %{conversation_id: "c1"}}

    assert :error = Memory.lookup(store, token)
    :ok = Memory.put(store, token, session)
    assert {:ok, ^session} = Memory.lookup(store, token)
    assert Memory.tokens(store) == [token]

    :ok = Memory.delete(store, token)
    assert :error = Memory.lookup(store, token)
    assert Memory.tokens(store) == []
  end

  test "the store behaviour dispatches both shapes", %{store: store} do
    token = Memory.generate_token()
    :ok = Memory.put(store, token, %Session{})

    assert {:ok, %Session{}} = Store.lookup({Memory, store}, token)
    assert :error = Store.lookup({Memory, store}, "mb_other")
  end

  test "the default instance answers the one-argument callback" do
    start_supervised!(Memory)
    token = Memory.generate_token()
    :ok = Memory.put(token, %Session{})

    assert {:ok, %Session{}} = Memory.lookup(token)
    assert {:ok, %Session{}} = Store.lookup(Memory, token)
    :ok = Memory.delete(token)
    assert :error = Memory.lookup(token)
    assert Memory.tokens() == []
  end

  test "Session.expired?/2" do
    now = DateTime.utc_now()
    refute Session.expired?(%Session{expires_at: nil}, now)
    refute Session.expired?(%Session{expires_at: DateTime.add(now, 60, :second)}, now)
    assert Session.expired?(%Session{expires_at: DateTime.add(now, -60, :second)}, now)
  end
end
