defmodule Fountain.Conversations.PendingTest do
  @moduledoc """
  What a turn waits on (#1375), driven without a server: a permission request
  answered, denied by timeout and drained at the turn's end; a parked
  caller-tool call answered, expired and dropped. The peer is this process,
  so what would reach it is asserted as messages; the timers land here too.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.Pending

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())
    {:ok, conv: conv, turn: turn, pending: %Pending{}}
  end

  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  defp denials(conv_id) do
    Fountain.Repo.all(
      from(a in Fountain.Audit.Event,
        where: a.resource_id == ^conv_id and a.action == "conversation.permission_denied"
      )
    )
    |> Enum.map(& &1.metadata)
  end

  # A stand-in peer: a process that records the deny cast it receives.
  defp fake_peer do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_cast", {:deny_permission, id}} -> send(test, {:denied, id})
      end
    end)
  end

  describe "from_state/1 and into_state/2" do
    test "round-trip the two server fields" do
      state = %{caller_calls: %{"c" => %{}}, permission_timer: :t, other: 1}
      assert %Pending{calls: %{"c" => %{}}, permission_timer: :t} = p = Pending.from_state(state)

      assert Pending.into_state(state, %{p | permission_timer: nil}) == %{
               state
               | permission_timer: nil
             }
    end
  end

  describe "a permission request" do
    test "ask/6 puts it on the row, announces it and arms the timeout", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes", "no"])

      assert %{"request_id" => 7, "tool" => "bash", "options" => ["yes", "no"], "asked_at" => _} =
               turn.pending_permission

      assert Fountain.Repo.get!(Conversations.Turn, turn.id).pending_permission["tool"] == "bash"

      assert [{"started", %{"request_id" => 7, "tool" => "bash", "timeout_ms" => ms}}] =
               stages(conv.id, "request")

      assert is_integer(ms) and ms > 0
      assert is_reference(pending.permission_timer)
      assert Process.read_timer(pending.permission_timer) > 0
      Process.cancel_timer(pending.permission_timer)
    end

    test "ask/6 with no turn announces and arms, with nothing to persist on", %{
      conv: conv,
      pending: pending
    } do
      {nil, pending} = Pending.ask(pending, conv.id, nil, 7, "bash", [])
      assert [{"started", _}] = stages(conv.id, "request")
      Process.cancel_timer(pending.permission_timer)
    end

    test "pending_tool/1 reads the row" do
      assert Pending.pending_tool(%{pending_permission: %{"tool" => "bash"}}) == "bash"
      assert Pending.pending_tool(%{pending_permission: nil}) == nil
      assert Pending.pending_tool(nil) == nil
    end

    test "an answer clears the row, cancels the timer, says done and audits nothing", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes"])
      timer = pending.permission_timer
      peer = fake_peer()

      {turn, pending} =
        Pending.resolve_permission(pending, conv.id, turn, peer, 7, "answered", "yes")

      assert turn.pending_permission == nil
      assert pending.permission_timer == nil
      assert Process.read_timer(timer) == false

      assert [{"started", _}, {"done", %{"outcome" => "answered", "option_id" => "yes"}}] =
               stages(conv.id, "request")

      assert denials(conv.id) == []
      refute_receive {:denied, _}, 50
    end

    test "a timeout denies at the peer, says done (never failed) and audits the tool", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes"])
      peer = fake_peer()

      {turn, _pending} =
        Pending.resolve_permission(pending, conv.id, turn, peer, 7, "timeout", nil)

      assert turn.pending_permission == nil
      assert_receive {:denied, 7}

      assert [{"started", _}, {"done", %{"outcome" => "timeout", "option_id" => nil}}] =
               stages(conv.id, "request")

      assert [%{"tool" => "bash", "verdict" => "timeout"}] = denials(conv.id)
    end

    test "resolve_pending_permission/5 drains whatever the row holds, and nothing otherwise", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      assert {^turn, ^pending} =
               Pending.resolve_pending_permission(pending, conv.id, turn, nil, "turn_ended")

      assert {nil, ^pending} =
               Pending.resolve_pending_permission(pending, conv.id, nil, nil, "turn_ended")

      {turn, pending} = Pending.ask(pending, conv.id, turn, 9, "rm", [])

      {turn, pending} =
        Pending.resolve_pending_permission(pending, conv.id, turn, nil, "turn_ended")

      assert turn.pending_permission == nil
      assert pending.permission_timer == nil
      assert [%{"tool" => "rm", "verdict" => "turn_ended"}] = denials(conv.id)
    end

    test "answer_permission/6 hands the option to the peer first, and is an error with no peer",
         %{
           conv: conv,
           turn: turn,
           pending: pending
         } do
      assert {{:error, :no_pending_permission}, ^turn, ^pending} =
               Pending.answer_permission(pending, conv.id, turn, nil, 7, "yes")

      test = self()

      peer =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:answer_permission, 7, "yes"}} ->
              send(test, :peer_took_it)
              GenServer.reply(from, :ok)
          end
        end)

      {turn, pending} = Pending.ask(pending, conv.id, turn, 7, "bash", ["yes"])

      assert {:ok, turn, pending} =
               Pending.answer_permission(pending, conv.id, turn, peer, 7, "yes")

      assert_receive :peer_took_it
      assert turn.pending_permission == nil
      assert pending.permission_timer == nil

      refusing =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, _} -> GenServer.reply(from, {:error, :unknown_option})
          end
        end)

      assert {{:error, :unknown_option}, ^turn, ^pending} =
               Pending.answer_permission(pending, conv.id, turn, refusing, 7, "made-up")
    end
  end

  describe "a parked caller-tool call" do
    test "park/6 announces it, arms a deadline and lists it oldest first", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {id1, pending} = Pending.park(pending, conv.id, turn, "lookup", %{"a" => 1}, self())
      # Oldest first is by the monotonic millisecond a call was parked at, so
      # two parks in the same millisecond have no order to assert.
      Process.sleep(2)
      {id2, pending} = Pending.park(pending, conv.id, turn, "other", %{}, nil)

      assert String.starts_with?(id1, "call_")

      assert [%{id: ^id1, name: "lookup", arguments: %{"a" => 1}}, %{id: ^id2, name: "other"}] =
               Pending.calls(pending)

      assert [
               {"started", %{"call_id" => ^id1, "name" => "lookup", "arguments" => %{"a" => 1}}},
               {"started", _}
             ] =
               stages(conv.id, "caller_tool")

      for call <- Map.values(pending.calls), do: Process.cancel_timer(call.timer)
    end

    test "await/3 is pending until resolved, then the kept result; unknown ids are refused", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {id, pending} = Pending.park(pending, conv.id, turn, "lookup", %{}, nil)

      assert {:pending, pending} = Pending.await(pending, id, self())
      assert pending.calls[id].waiter == self()
      assert {{:error, :unknown_call}, ^pending} = Pending.await(pending, "call_nope", self())

      pending = Pending.resolve_call(pending, conv.id, id, "answered", {:ok, "shipped"})
      assert_receive {:caller_tool_result, ^id, {:ok, "shipped"}}
      assert {{:ok, {:ok, "shipped"}}, ^pending} = Pending.await(pending, id, self())
    end

    test "answer_calls/3 resolves the matched ids, ignores strays and reports the rest", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {a, pending} = Pending.park(pending, conv.id, turn, "a", %{}, self())
      {b, pending} = Pending.park(pending, conv.id, turn, "b", %{}, nil)

      assert {{:ok, %{turn_id: turn_id, remaining: [%{id: ^b}]}}, pending} =
               Pending.answer_calls(pending, conv.id, %{a => "one", "stray" => "x"})

      assert turn_id == turn.id
      assert_receive {:caller_tool_result, ^a, {:ok, "one"}}
      assert Pending.calls(pending) |> Enum.map(& &1.id) == [b]

      assert [_, _, {"done", %{"call_id" => ^a, "outcome" => "answered"}}] =
               stages(conv.id, "caller_tool")

      assert {{:error, :no_pending_calls}, ^pending} =
               Pending.answer_calls(pending, conv.id, %{a => "again"})

      Process.cancel_timer(pending.calls[b].timer)
    end

    test "resolve_call/5 cancels the deadline and resolves once", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {id, pending} = Pending.park(pending, conv.id, turn, "a", %{}, nil)
      timer = pending.calls[id].timer

      pending = Pending.resolve_call(pending, conv.id, id, "timeout", {:error, "late"})
      assert Process.read_timer(timer) == false
      assert %{result: {:error, "late"}, timer: nil, waiter: nil} = pending.calls[id]

      assert ^pending = Pending.resolve_call(pending, conv.id, id, "answered", {:ok, "x"})
      assert [_, {"done", %{"outcome" => "timeout"}}] = stages(conv.id, "caller_tool")
    end

    test "drop_calls/3 errors what is still parked and empties the registry", %{
      conv: conv,
      turn: turn,
      pending: pending
    } do
      {a, pending} = Pending.park(pending, conv.id, turn, "a", %{}, self())
      {b, pending} = Pending.park(pending, conv.id, turn, "b", %{}, self())
      pending = Pending.resolve_call(pending, conv.id, a, "answered", {:ok, "done"})

      pending = Pending.drop_calls(pending, conv.id, "turn_ended")

      assert pending.calls == %{}

      assert_receive {:caller_tool_result, ^b,
                      {:error, "the turn ended before the caller answered"}}

      assert [
               _,
               _,
               {"done", %{"call_id" => ^a}},
               {"done", %{"call_id" => ^b, "outcome" => "turn_ended"}}
             ] =
               stages(conv.id, "caller_tool")
    end
  end
end
