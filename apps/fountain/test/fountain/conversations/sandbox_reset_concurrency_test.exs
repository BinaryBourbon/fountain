defmodule Fountain.Conversations.SandboxResetConcurrencyTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox, as: SQLSandbox
  alias Fountain.Conversations

  setup :set_mimic_global

  for first <- [:original, :retry] do
    test "#{first} and a competing retry publish only the winning completion" do
      SQLSandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        home = insert_sandbox(user_id: user.id, mode: "persistent", status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: home, status: "idle")
        owner = self()

        if unquote(first) == :retry do
          stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :timeout} end)
          assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(home)
        end

        stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
          refute Repo.in_transaction?()
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(owner, {:deleting, self(), backend})

          receive do
            :confirmed -> :ok
          after
            5_000 -> flunk("delete barrier timed out")
          end
        end)

        original =
          independent(fn ->
            if unquote(first) == :original,
              do: Conversations.reset_sandbox(home),
              else: Conversations.retry_pending_sandbox_reset(home)
          end)

        try do
          assert_receive {:deleting, original_pid, original_backend}, 5_000
          assert original_pid == original.pid
          retry = independent(fn -> Conversations.retry_pending_sandbox_reset(home) end)

          try do
            assert_receive {:deleting, retry_pid, retry_backend}, 5_000
            assert retry_pid == retry.pid
            refute original_backend == retry_backend
            assert Fountain.Quotas.active_sandbox_count(user.id) == 1
            send(retry.pid, :confirmed)
            assert {:ok, %{status: "terminated"}} = Task.await(retry, 5_000)
            assert Fountain.Quotas.active_sandbox_count(user.id) == 0

            # A holder can now move to a replacement. Register its new server
            # before the old request returns: the loser must send it nothing.
            replacement = insert_sandbox(user_id: user.id, status: "ready")
            {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
            {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv.id, nil)
            send(original.pid, :confirmed)
            assert {:ok, :skipped} = Task.await(original, 5_000)
            refute_received {:"$gen_cast", _}

            assert Repo.aggregate(
                     from(a in Fountain.Audit.Event,
                       where: a.resource_id == ^home.id and a.action == "sandbox.reset"
                     ),
                     :count
                   ) == 1

            assert [_] =
                     Enum.filter(
                       Conversations._unsafe_list_log_events(conv.id),
                       &(&1.stage == "sandbox")
                     )
          after
            Task.shutdown(retry, :brutal_kill)
          end
        after
          Horde.Registry.unregister(Fountain.ConversationRegistry, conv.id)
          Task.shutdown(original, :brutal_kill)
          Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
          Repo.delete_all(from s in Conversations.Sandbox, where: s.user_id == ^user.id)
          Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
          Repo.delete_all(from a in Fountain.Agents.Agent, where: a.user_id == ^user.id)
          Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
        end
      end)
    end
  end

  test "a rebound holder wins while an old reset notification waits for its row" do
    SQLSandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      home = insert_sandbox(user_id: user.id, mode: "persistent", status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: home, status: "idle")
      replacement = insert_sandbox(user_id: user.id, status: "ready")
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
      assert {:ok, _} = Conversations.reset_sandbox(home)
      Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")
      owner = self()

      state = %{
        conversation_id: conv.id,
        user_id: user.id,
        sandbox_id: home.id,
        current_turn: nil,
        turn_execution: nil,
        handle: nil
      }

      moving =
        independent(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from c in Conversations.Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE"
            )

            send(owner, :holder_locked)

            receive do
              :move -> :ok
            after
              5_000 -> flunk("holder barrier timed out")
            end

            {:ok, moved} =
              Conversations.update_conversation(conv, %{
                sandbox_id: replacement.id,
                status: "running"
              })

            insert_turn(moved, status: "running")
          end)
        end)

      try do
        assert_receive :holder_locked, 5_000

        notification =
          independent(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:notification_backend, backend})

            Conversations.MachineEvents.reset(
              state,
              home.id,
              "reset_reconciled",
              "system",
              "late",
              fn _, _ ->
                flunk("old notification must not close the replacement's connection")
              end
            )
          end)

        try do
          assert_receive {:notification_backend, backend}, 5_000
          await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          send(moving.pid, :move)
          assert {:ok, turn} = Task.await(moving, 5_000)
          assert {:noreply, ^state} = Task.await(notification, 5_000)
          assert Repo.reload!(conv).sandbox_id == replacement.id
          assert Repo.reload!(conv).status == "running"
          assert Repo.reload!(turn).status == "running"
          assert_receive {:sidebar_update, user_id}
          assert user_id == user.id
          refute_received {:sidebar_update, _}

          assert [_] =
                   Enum.filter(
                     Conversations._unsafe_list_log_events(conv.id),
                     &(&1.stage == "sandbox")
                   )
        after
          Task.shutdown(notification, :brutal_kill)
        end
      after
        Task.shutdown(moving, :brutal_kill)
        Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
        Repo.delete_all(from s in Conversations.Sandbox, where: s.user_id == ^user.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from a in Fountain.Agents.Agent, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_blocked(backend, deadline)
    end
  end

  defp independent(fun) do
    Task.async(fn -> SQLSandbox.unboxed_run(Repo, fun) end)
  end
end
