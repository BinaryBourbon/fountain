defmodule Fountain.Conversations.LogEventCommitOrderTest do
  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Conversations

  for outcome <- [:commit, :rollback] do
    test "an account's later event waits for #{outcome}, while another account can commit" do
      assert_commit_order(unquote(outcome))
    end
  end

  defp assert_commit_order(outcome) do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      other = insert_verified_user()
      first = insert_conversation(user_id: user.id)
      second = insert_conversation(user_id: user.id)
      foreign = insert_conversation(user_id: other.id)
      owner = self()

      held =
        independent(fn ->
          Repo.transaction(fn ->
            event = append(first)
            send(owner, {:inserted_before_commit, event})

            receive do
              :finish ->
                if outcome == :commit, do: event, else: Repo.rollback(:fixture_abort)
            after
              15_000 -> Repo.rollback(:test_timeout)
            end
          end)
        end)

      try do
        assert_receive {:inserted_before_commit, early}, 5_000
        waiting = independent(fn -> append(second) end)

        try do
          assert_receive {:backend, held_pid, held_backend}, 5_000
          assert held_pid == held.pid
          assert_receive {:backend, waiting_pid, waiting_backend}, 5_000
          assert waiting_pid == waiting.pid
          refute held_backend == waiting_backend
          await_blocked(waiting_backend, System.monotonic_time(:millisecond) + 5_000)
          assert Conversations.list_user_log_events(user.id, 0) == []

          unrelated = independent(fn -> append(foreign) end)

          try do
            assert {:ok, foreign_event} = Task.yield(unrelated, 2_000)
            assert foreign_event.conversation_id == foreign.id
            assert Task.yield(waiting, 0) == nil
            send(held.pid, :finish)
            held_result = Task.await(held, 5_000)
            later = Task.await(waiting, 5_000)
            assert later.id > early.id

            events = Conversations.list_user_log_events(user.id, 0)
            ids = Enum.map(events, fn {event, _runtime} -> event.id end)

            if outcome == :commit do
              assert held_result == {:ok, early}
              assert ids == [early.id, later.id]
            else
              assert held_result == {:error, :fixture_abort}
              assert ids == [later.id]
            end

            assert [{remaining, _}] = Conversations.list_user_log_events(user.id, early.id)
            assert remaining.id == later.id
          after
            Task.shutdown(unrelated, :brutal_kill)
          end
        after
          Task.shutdown(waiting, :brutal_kill)
        end
      after
        send(held.pid, :finish)
        Task.shutdown(held, :brutal_kill)
        ids = [user.id, other.id]
        sandbox_ids = [first.sandbox_id, second.sandbox_id, foreign.sandbox_id]
        Repo.delete_all(from c in Conversations.Conversation, where: c.user_id in ^ids)
        Repo.delete_all(from s in Conversations.Sandbox, where: s.id in ^sandbox_ids)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id in ^ids)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id in ^ids)
      end
    end)
  end

  defp append(conversation) do
    Conversations.log!(%{
      conversation_id: conversation.id,
      kind: "output",
      stream: "stdout",
      data: "fixture output"
    })
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "the later event did not wait for the account's uncommitted event"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
