defmodule Fountain.Conversations.ExecutionGuardTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.{ExecutionGuard, Turn, TurnExecution}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conversation = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    now = DateTime.utc_now()

    turn =
      insert_turn(conversation, status: "running", started_at: DateTime.truncate(now, :second))

    deadline = DateTime.add(now, 60, :second)
    connection = Ecto.UUID.generate()
    {:ok, execution} = ExecutionGuard._unsafe_register(turn.id, connection, deadline, now: now)

    %{
      user: user,
      sandbox: sandbox,
      conversation: conversation,
      turn: turn,
      now: now,
      deadline: deadline,
      connection: connection,
      execution: execution
    }
  end

  defp bind(context) do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(context.execution.id, now: context.now)

    {:ok, bound} =
      ExecutionGuard._unsafe_bind_identity(context.execution.id, context.connection, "19")

    bound
  end

  defp submitted(context) do
    bind(context)
    {:ok, _} = ExecutionGuard._unsafe_expire(context.execution.id, now: context.deadline)

    {:ok, %{permitted: true, execution: execution}} =
      ExecutionGuard._unsafe_claim_termination(context.execution.id, now: context.deadline)

    execution
  end

  test "registration derives ownership and retries cannot extend the deadline", c do
    assert c.execution.user_id == c.user.id
    assert c.execution.sandbox_id == c.sandbox.id
    assert c.execution.sandbox_name == c.sandbox.sprite_name
    assert c.execution.provider == c.sandbox.provider
    assert {:ok, again} = ExecutionGuard._unsafe_register(c.turn.id, c.connection, c.deadline)
    assert again.id == c.execution.id

    assert {:error, :immutable_execution} =
             ExecutionGuard._unsafe_register(
               c.turn.id,
               c.connection,
               DateTime.add(c.deadline, 60)
             )

    assert {:error, :immutable_execution} =
             ExecutionGuard._unsafe_register(c.turn.id, Ecto.UUID.generate(), c.deadline)

    assert Repo.aggregate(TurnExecution, :count) == 1
  end

  test "stale or malformed identity cannot choose a different session", c do
    assert {:error, :stale_connection} =
             ExecutionGuard._unsafe_bind_identity(c.execution.id, Ecto.UUID.generate(), "other")

    assert {:error, :invalid_session_id} =
             ExecutionGuard._unsafe_bind_identity(c.execution.id, c.connection, "../other")

    assert Repo.get!(TurnExecution, c.execution.id).provider_session_id == nil
  end

  test "conflicting identity fences the turn without replacing its original binding", c do
    bind(c)

    assert {:ok, %{state: "uncertain", provider_session_id: "19"}} =
             ExecutionGuard._unsafe_bind_identity(c.execution.id, c.connection, "20")

    assert Repo.get!(Turn, c.turn.id).status == "failed"
    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)
    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(c.execution.id)
  end

  test "expiry with no identity waits for a late trusted binding", c do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id, now: c.now)

    assert {:ok, %{execution: %{state: "awaiting_identity"}, turn: turn}} =
             ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    assert turn.status == "failed"
    assert turn.limit_reason == "wall_time_limit"
    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(c.execution.id)

    assert {:ok, %{state: "ready", deadline_at: deadline}} =
             ExecutionGuard._unsafe_bind_identity(c.execution.id, c.connection, "19")

    assert deadline == c.deadline
  end

  test "early completion prevents a stale deadline from killing a reused connection", c do
    bind(c)

    assert {:ok, %{turn: %{status: "completed"}}} =
             ExecutionGuard._unsafe_complete(c.execution.id, "completed", now: c.now)

    successor = insert_turn(c.conversation, status: "running")

    assert {:ok, next} =
             ExecutionGuard._unsafe_register(
               successor.id,
               c.connection,
               DateTime.add(c.deadline, 60)
             )

    assert {:ok, %{execution: %{state: "completed"}, turn: %{status: "completed"}}} =
             ExecutionGuard._unsafe_expire(c.execution.id, now: DateTime.add(c.deadline, 1))

    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(c.execution.id)
    assert Repo.get!(TurnExecution, next.id).state == "active"
    assert Repo.get!(Turn, successor.id).status == "running"
  end

  test "completion exactly at the deadline is failure and retains partial usage", c do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id, now: c.now)

    c.turn
    |> change(usage: %{"input" => 42, "accounting" => %{"complete" => false}})
    |> Repo.update!()

    assert {:ok, %{turn: turn, execution: %{state: "awaiting_identity"}}} =
             ExecutionGuard._unsafe_complete(c.execution.id, "completed", now: c.deadline)

    assert turn.status == "failed"
    assert turn.limit_reason == "wall_time_limit"
    assert turn.usage["input"] == 42
    assert turn.usage["accounting"]["complete"] == false
  end

  test "expiry wins against a late success and blocks a successor", c do
    bind(c)

    assert {:ok, %{turn: expired}} =
             ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    assert {:ok, %{turn: late}} =
             ExecutionGuard._unsafe_complete(c.execution.id, "completed",
               now: DateTime.add(c.deadline, 1)
             )

    assert late.status == "failed"
    assert late.ended_at == expired.ended_at
    successor = insert_turn(c.conversation, status: "running")

    assert {:error, :execution_fenced} =
             ExecutionGuard._unsafe_register(
               successor.id,
               Ecto.UUID.generate(),
               DateTime.add(c.deadline, 60)
             )
  end

  test "an existing failure cannot be overwritten by a later completion", c do
    c.turn
    |> change(status: "failed", ended_at: DateTime.truncate(c.now, :second))
    |> Repo.update!()

    assert {:ok, %{turn: %{status: "failed"}, execution: %{state: "stopped"}}} =
             ExecutionGuard._unsafe_complete(c.execution.id, "completed", now: c.now)

    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(c.execution.id)
  end

  test "the persisted attempt grants exactly one provider write", c do
    execution = submitted(c)
    assert execution.attempt_id
    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(c.execution.id)
    reloaded = Repo.get!(TurnExecution, c.execution.id)
    assert reloaded.attempt_id == execution.attempt_id

    assert {:error, :stale_attempt} =
             ExecutionGuard._unsafe_record_termination(execution.id, Ecto.UUID.generate(), :ok)

    assert Repo.get!(TurnExecution, execution.id).state == "submitted"
  end

  test "lost acknowledgment remains fenced; a matching late acknowledgment can resolve it", c do
    execution = submitted(c)

    assert {:ok, %{state: "uncertain"}} =
             ExecutionGuard._unsafe_record_termination(
               execution.id,
               execution.attempt_id,
               {:error, :timeout}
             )

    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)
    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(execution.id)

    assert {:ok, %{state: "stopped"}} =
             ExecutionGuard._unsafe_record_termination(execution.id, execution.attempt_id, :ok)

    refute ExecutionGuard._unsafe_fenced?(c.conversation.id)
    assert Repo.get!(Turn, c.turn.id).status == "failed"

    assert {:ok, %{state: "stopped"}} =
             ExecutionGuard._unsafe_record_termination(execution.id, execution.attempt_id, :ok)
  end

  test "a changed sandbox binding prevents the provider write", c do
    bind(c)
    ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")
    c.conversation |> change(sandbox_id: replacement.id) |> Repo.update!()

    assert {:ok,
            %{permitted: false, execution: %{state: "uncertain", last_error: "ownership_changed"}}} =
             ExecutionGuard._unsafe_claim_termination(c.execution.id)

    assert Repo.get!(TurnExecution, c.execution.id).attempt_id == nil
    assert Repo.get!(TurnExecution, c.execution.id).sandbox_id == c.sandbox.id
  end

  test "another conversation on the same sandbox remains usable", c do
    submitted(c)
    neighbor = insert_conversation(user_id: c.user.id, sandbox: c.sandbox, status: "running")
    turn = insert_turn(neighbor, status: "running")
    assert {:ok, _} = ExecutionGuard._unsafe_register(turn.id, Ecto.UUID.generate(), c.deadline)
    refute ExecutionGuard._unsafe_fenced?(neighbor.id)
  end

  test "the journal retains uncertain intent if a transcript turn is removed", c do
    execution = submitted(c)
    Repo.delete!(c.turn)
    assert Repo.get!(TurnExecution, execution.id).state == "submitted"
    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(execution.id)

    assert {:ok, %{state: "uncertain"}} =
             ExecutionGuard._unsafe_record_termination(execution.id, execution.attempt_id, :lost)
  end

  test "a deleted active turn becomes uncertain rather than remaining in the due queue", c do
    Repo.delete!(c.turn)

    assert {:ok, %{turn: nil, execution: %{state: "uncertain", last_error: "turn_missing"}}} =
             ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    assert ExecutionGuard._unsafe_due(c.deadline) == []
  end

  test "identity conflict after submission cannot be cleared by acknowledgment of the old target",
       c do
    execution = submitted(c)
    ExecutionGuard._unsafe_bind_identity(execution.id, c.connection, "20")

    assert {:error, :binding_uncertain} =
             ExecutionGuard._unsafe_record_termination(execution.id, execution.attempt_id, :ok)

    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)
  end

  test "an expired deadline before spawn has no remote cleanup obligation", c do
    assert {:ok, %{execution: %{state: "stopped"}, turn: %{status: "failed"}}} =
             ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    refute ExecutionGuard._unsafe_fenced?(c.conversation.id)
    assert {:error, :spawn_not_ready} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)
  end

  test "an uncertain spawn is not replayed or released by an early failure", c do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id, now: c.now)

    assert {:error, :spawn_not_ready} =
             ExecutionGuard._unsafe_claim_spawn(c.execution.id, now: c.now)

    assert {:ok, %{execution: %{state: "awaiting_identity"}, turn: %{status: "failed"}}} =
             ExecutionGuard._unsafe_complete(c.execution.id, "failed", now: c.now)

    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)

    assert {:ok, %{state: "ready"}} =
             ExecutionGuard._unsafe_bind_identity(c.execution.id, c.connection, "19")
  end

  test "identity cannot be bound before the recorded spawn intent", c do
    assert {:error, :spawn_not_submitted} =
             ExecutionGuard._unsafe_bind_identity(c.execution.id, c.connection, "19")

    assert {:error, :execution_not_started} =
             ExecutionGuard._unsafe_complete(c.execution.id, "completed", now: c.now)
  end

  test "a confirmed stopped connection cannot be reused by a new turn", c do
    execution = submitted(c)
    {:ok, _} = ExecutionGuard._unsafe_record_termination(execution.id, execution.attempt_id, :ok)
    successor = insert_turn(c.conversation, status: "running")

    assert {:error, :connection_retired} =
             ExecutionGuard._unsafe_register(
               successor.id,
               c.connection,
               DateTime.add(c.deadline, 60)
             )

    assert {:ok, _} =
             ExecutionGuard._unsafe_register(
               successor.id,
               Ecto.UUID.generate(),
               DateTime.add(c.deadline, 60)
             )
  end

  test "the existing turn writer cannot overwrite expiry or reopen permissions", c do
    bind(c)
    {:ok, %{turn: expired}} = ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    {:ok, updated} =
      Fountain.Conversations._unsafe_update_turn(c.turn, %{
        status: "completed",
        exit_code: 0,
        ended_at: DateTime.truncate(DateTime.add(c.deadline, 90), :second),
        pending_permission: %{"id" => "late"}
      })

    assert updated.status == "failed"
    assert updated.limit_reason == "wall_time_limit"
    assert updated.exit_code == nil
    assert updated.pending_permission == nil
    assert updated.ended_at == expired.ended_at
  end

  test "the existing turn writer preserves an accepted nonzero command exit", c do
    bind(c)

    {:ok, updated} =
      Fountain.Conversations._unsafe_update_turn(c.turn, %{status: "failed", exit_code: 7})

    assert updated.status == "failed"
    assert updated.exit_code == 7
    assert Repo.get!(TurnExecution, c.execution.id).state == "ready"
    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)
  end

  test "string-keyed late writes cannot bypass the terminal fence", c do
    bind(c)
    ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    {:ok, updated} =
      Fountain.Conversations._unsafe_update_turn(c.turn, %{
        "status" => "completed",
        "exit_code" => 0,
        "limit_reason" => nil
      })

    assert updated.status == "failed"
    assert updated.limit_reason == "wall_time_limit"
    assert updated.exit_code == nil
  end

  test "the real turn finisher emits failure after a late successful response", c do
    bind(c)
    ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)
    machine = %Fountain.Conversations.TurnMachine{conversation_id: c.conversation.id, row: c.turn}

    Fountain.Conversations.TurnMachine.finish(machine, "completed", %{}, %{
      stop_reason: "end_turn"
    })

    events =
      Repo.all(
        from e in Fountain.Conversations.LogEvent,
          where: e.conversation_id == ^c.conversation.id and e.stage == "turn"
      )

    assert [event] = events
    assert event.state == "failed"
    assert Jason.decode!(event.data)["limit_reason"] == "wall_time_limit"
    assert Repo.get!(Turn, c.turn.id).status == "failed"
  end

  test "interrupting a known command retains its fence until remote confirmation", c do
    bind(c)

    assert {:ok, %{turn: %{status: "interrupted"}, execution: %{state: "ready"}}} =
             ExecutionGuard._unsafe_complete(c.execution.id, "interrupted", now: c.now)

    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)

    assert {:ok, %{permitted: true, execution: attempt}} =
             ExecutionGuard._unsafe_claim_termination(c.execution.id)

    assert {:ok, %{state: "stopped"}} =
             ExecutionGuard._unsafe_record_termination(c.execution.id, attempt.attempt_id, :ok)

    refute ExecutionGuard._unsafe_fenced?(c.conversation.id)
    assert Repo.get!(Turn, c.turn.id).status == "interrupted"
  end

  test "an out-of-band failure cannot silently abandon a known remote command", c do
    bind(c)
    ended = DateTime.truncate(c.now, :second)
    c.turn |> change(status: "failed", ended_at: ended) |> Repo.update!()

    assert {:ok, %{turn: %{status: "failed", ended_at: ^ended}, execution: %{state: "ready"}}} =
             ExecutionGuard._unsafe_expire(c.execution.id, now: c.deadline)

    assert ExecutionGuard._unsafe_fenced?(c.conversation.id)
  end

  test "a reset sandbox cannot admit a bounded command through a stale parent", c do
    ExecutionGuard._unsafe_complete(c.execution.id, "failed", now: c.now)
    c.sandbox |> change(status: "terminated") |> Repo.update!()
    successor = insert_turn(c.conversation, status: "running")

    assert {:error, :sandbox_not_ready} =
             ExecutionGuard._unsafe_register(successor.id, Ecto.UUID.generate(), c.deadline)
  end

  test "restart recovery retains the attempt and never replays termination", c do
    attempt = submitted(c)
    cutoff = DateTime.add(c.deadline, 30)

    assert ExecutionGuard._unsafe_recover_submissions(DateTime.add(c.deadline, -1)) == []
    assert [{:ok, recovered}] = ExecutionGuard._unsafe_recover_submissions(cutoff)
    assert recovered.state == "uncertain"
    assert recovered.attempt_id == attempt.attempt_id
    assert recovered.submitted_at == attempt.submitted_at
    assert recovered.deadline_at == c.deadline
    assert {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(attempt.id)
    assert ExecutionGuard._unsafe_recover_submissions(cutoff) == []

    assert {:ok, %{state: "stopped"}} =
             ExecutionGuard._unsafe_record_termination(attempt.id, attempt.attempt_id, :ok)
  end

  test "submission recovery cannot downgrade a confirmed operation", c do
    attempt = submitted(c)
    {:ok, _} = ExecutionGuard._unsafe_record_termination(attempt.id, attempt.attempt_id, :ok)
    assert ExecutionGuard._unsafe_recover_submissions(DateTime.add(c.deadline, 30)) == []
    assert Repo.get!(TurnExecution, attempt.id).state == "stopped"
  end

  test "a terminal or deleted turn cannot authorize a late spawn", c do
    c.turn |> change(status: "failed") |> Repo.update!()
    assert {:error, :turn_not_running} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)
    Repo.delete!(c.turn)
    assert {:error, :turn_not_running} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)
    assert Repo.get!(TurnExecution, c.execution.id).spawn_submitted_at == nil
  end

  test "binding, original deadline and attempt cannot be cleared or rewritten", c do
    execution = submitted(c)

    for attrs <- [
          %{deadline_at: DateTime.add(c.deadline, 60)},
          %{sandbox_name: "replacement"},
          %{provider_session_id: nil},
          %{attempt_id: nil}
        ] do
      refute TurnExecution.changeset(execution, attrs).valid?
    end
  end
end
