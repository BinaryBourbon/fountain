defmodule Fountain.Conversations.ConversationServerRegistrySettleTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer

  # `await_registered/2` is the settle window that stops the #800
  # duplicate-sandbox race. Its contract is "look more than once", so the
  # tests here drive the registry lookup itself rather than a wake, and no
  # test needs a database.

  defp counting_registry(results) do
    {:ok, polls} = Agent.start_link(fn -> 0 end)

    stub(Horde.Registry, :lookup, fn Fountain.ConversationRegistry, _key ->
      n = Agent.get_and_update(polls, &{&1, &1 + 1})
      Enum.at(results, n, List.last(results))
    end)

    polls
  end

  test "an expired window still costs a second lookup (#1429)" do
    server = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(server, :kill) end)

    # The registry catches up on the second poll, exactly as in the #800 wake
    # test. A zero-millisecond window stands in for the scheduling stall that
    # made the real 150 ms one expire before the first lookup: with the
    # deadline checked ahead of the first poll, this returned `:timeout`
    # having looked once, which is the behaviour #800 removed.
    polls = counting_registry([[], [{server, nil}]])

    assert {:ok, ^server} = ConversationServer.await_registered("conv-1429", 0)
    assert Agent.get(polls, & &1) == 2
  end

  test "a registry that never catches up still times out" do
    polls = counting_registry([[]])

    assert :timeout = ConversationServer.await_registered("conv-absent", 0)

    # Bounded by the guarantee, not by the clock: the expired window ends it
    # on the second miss rather than polling until the deadline.
    assert Agent.get(polls, & &1) == 2
  end

  test "a server already in the registry is returned without waiting" do
    server = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(server, :kill) end)

    polls = counting_registry([[{server, nil}]])

    assert {:ok, ^server} = ConversationServer.await_registered("conv-present", 0)
    assert Agent.get(polls, & &1) == 1
  end
end
