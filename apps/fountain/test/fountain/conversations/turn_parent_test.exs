defmodule Fountain.Conversations.TurnParentTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ExecutionGuard, Turn, TurnExecution, TurnMachine}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        sandbox: sandbox,
        status: "running",
        runtime_session_id: "original-session"
      )

    turn = insert_turn(conv, status: "running")

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    %{conv: conv, turn: turn, execution: execution, sandbox: sandbox}
  end

  defp machine(c), do: %TurnMachine{conversation_id: c.conv.id, row: c.turn}

  defp actor(c),
    do: %{
      conversation_id: c.conv.id,
      current_turn: c.turn,
      runtime_session_id: "original-session"
    }

  defp successor(c) do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    next = insert_turn(c.conv, status: "running")

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        next.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {next, execution}
  end

  test "stale completion cannot idle a successor admitted after cancellation", c do
    {next, execution} = successor(c)
    TurnMachine.finish(machine(c), "completed", %{}, %{})
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
    assert Repo.get!(TurnExecution, execution.id).state == "active"
  end

  test "the interrupt's delayed second half cannot idle a successor", c do
    {next, _} = successor(c)
    TurnMachine.close_interrupted(machine(c))
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "the current ended generation can idle its parent", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)

    assert {:ok, %{applied: true, conversation: %{status: "idle"}}} =
             Conversations._unsafe_idle_after_turn(c.turn)

    assert {:ok, %{applied: false}} = Conversations._unsafe_idle_after_turn(c.turn)
  end

  test "a running turn cannot idle itself", c do
    assert {:ok, %{applied: false}} = Conversations._unsafe_idle_after_turn(c.turn)
    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end

  test "late terminal callbacks preserve terminated and failed parents", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)

    for status <- ["terminated", "failed"] do
      c.conv |> Ecto.Changeset.change(status: status) |> Repo.update!()
      TurnMachine.close_interrupted(machine(c))
      assert Repo.get!(Conversation, c.conv.id).status == status
    end
  end

  test "session reports update durable and actor state while their turn is current", c do
    state = TurnMachine.accept_runtime_session(actor(c), "new-session")
    assert state.runtime_session_id == "new-session"
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "new-session"
  end

  test "late session reports and resets cannot change the successor's session or old actor state",
       c do
    successor(c)
    c.conv |> Ecto.Changeset.change(runtime_session_id: "successor-session") |> Repo.update!()
    old = actor(c)
    assert ^old = TurnMachine.accept_runtime_session(old, "late-session")
    assert ^old = TurnMachine.forget_turn_session(old, "session_gone", "old peer")
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "successor-session"
  end

  test "retirement alone fences session writes even before a successor exists", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)

    assert {:ok, %{applied: false}} =
             Conversations._unsafe_set_turn_session(c.turn, "late-session")

    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
  end

  test "the session writer enforces expiration without a coordinator tick", c do
    c.execution
    |> Ecto.Changeset.change(deadline_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, %{applied: false}} =
             Conversations._unsafe_set_turn_session(c.turn, "late-session")

    assert Repo.get!(Turn, c.turn.id).limit_reason == "wall_time_limit"
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
  end

  test "a current missing-session report clears only its own session", c do
    assert %{runtime_session_id: nil} =
             TurnMachine.forget_turn_session(actor(c), "session_gone", "gone")

    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == nil
  end

  test "changed sandbox identity and a forged parent cannot authorize a session write", c do
    c.sandbox |> Ecto.Changeset.change(sprite_name: "replacement") |> Repo.update!()

    assert {:ok, %{applied: false}} =
             Conversations._unsafe_set_turn_session(c.turn, "wrong-machine")

    other = insert_conversation(user_id: insert_verified_user().id)

    assert {:error, :ownership_changed} =
             Conversations._unsafe_set_turn_session(
               %{c.turn | conversation_id: other.id},
               "wrong-tenant"
             )

    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
    assert Repo.get!(Conversation, other.id).runtime_session_id == nil
  end

  test "a deleted parent returns an explicit refusal", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    Repo.delete!(c.conv)
    assert {:error, :not_found} = Conversations._unsafe_idle_after_turn(c.turn)
    assert {:error, :not_found} = Conversations._unsafe_set_turn_session(c.turn, "orphan")
  end

  test "an idle peer cannot erase a bounded session even after cleanup completed", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    state = %{actor(c) | current_turn: nil}
    assert ^state = TurnMachine.forget_turn_session(state, "session_gone", "old")
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
  end

  test "idle legacy reset preserves its behavior but cannot clear a changed session" do
    conv =
      insert_conversation(
        user_id: insert_verified_user().id,
        status: "idle",
        runtime_session_id: "legacy"
      )

    state = %{conversation_id: conv.id, current_turn: nil, runtime_session_id: "old"}
    assert ^state = TurnMachine.forget_turn_session(state, "session_gone", "gone")

    assert %{runtime_session_id: nil} =
             TurnMachine.forget_turn_session(
               %{state | runtime_session_id: "legacy"},
               "session_gone",
               "gone"
             )

    assert Repo.get!(Conversation, conv.id).runtime_session_id == nil
  end

  test "orphan recovery retires a known command before idling the parent", c do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(
        c.execution.id,
        c.execution.connection_id,
        "orphan-command"
      )

    assert {:ok, updated, %{status: "idle"}} =
             Conversations._unsafe_orphan_turn(c.turn, "lost_actor")

    assert updated.status == "interrupted"
    assert updated.orphaned_at
    assert Repo.get!(TurnExecution, c.execution.id).state == "ready"
    assert {:ok, %{permitted: true}} = ExecutionGuard._unsafe_claim_termination(c.execution.id)
    assert :noop = Conversations._unsafe_orphan_turn(c.turn, "duplicate")
  end

  test "orphan recovery retains an unknown spawn and cannot authorize a replacement", c do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)
    assert {:ok, updated, _} = Conversations._unsafe_orphan_turn(c.turn, "lost_actor")
    assert updated.orphaned_at
    assert Repo.get!(TurnExecution, c.execution.id).state == "awaiting_identity"
    assert {:error, :execution_fenced} = ExecutionGuard._unsafe_admission_gate(c.conv.id)
  end

  test "orphan recovery preserves a deadline outcome and its durable event", c do
    c.execution
    |> Ecto.Changeset.change(deadline_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, updated, _} = Conversations._unsafe_orphan_turn(c.turn, "lost_actor")
    assert updated.status == "failed"
    assert updated.limit_reason == "wall_time_limit"
    assert updated.orphaned_at
    events = Repo.all(from e in Conversations.LogEvent, where: e.turn_id == ^c.turn.id)
    assert [%{state: "failed"}] = events
  end

  test "recovering an old already-ended turn leaves its successor untouched", c do
    {next, _} = successor(c)
    assert :noop = Conversations._unsafe_orphan_turn(c.turn, "stale_candidate")
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "legacy recovery closes its old turn without idling a newer running generation" do
    conv = insert_conversation(user_id: insert_verified_user().id, status: "running")
    old = insert_turn(conv, status: "running")
    next = insert_turn(conv, status: "running")

    assert {:ok, %{status: "interrupted"}, %{status: "running"}} =
             Conversations._unsafe_orphan_turn(old, "old_legacy")

    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "admission commits running status even when an older snapshot still said running", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    {:ok, _} = Conversations.update_conversation(c.conv, %{status: "idle"})

    attrs = %{
      conversation_id: c.conv.id,
      turn_number: 2,
      prompt: "next",
      status: "running",
      started_at: DateTime.utc_now()
    }

    assert {:ok, _} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)

    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end

  test "failed admission cannot leave an idle parent running", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    {:ok, _} = Conversations.update_conversation(c.conv, %{status: "idle"})
    attrs = %{conversation_id: c.conv.id, turn_number: 2, status: "running"}

    assert {:error, %Ecto.Changeset{}} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)

    assert Repo.get!(Conversation, c.conv.id).status == "idle"
  end

  test "closed parents refuse user and background admission without revival", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    attrs = %{conversation_id: c.conv.id, turn_number: 2, prompt: "late", status: "running"}

    for status <- ["terminated", "failed"] do
      c.conv |> Ecto.Changeset.change(status: status) |> Repo.update!()

      assert {:error, :not_running} =
               Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)

      assert {:error, :not_running} =
               Conversations._unsafe_create_autonomous_turn(attrs, c.sandbox.id)

      assert Repo.get!(Conversation, c.conv.id).status == status
    end

    assert Repo.aggregate(Turn, :count) == 1
  end

  test "a changed binding cannot expire or recover another machine's parent", c do
    c.sandbox |> Ecto.Changeset.change(sprite_name: "replacement") |> Repo.update!()

    c.execution
    |> Ecto.Changeset.change(deadline_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, %{applied: false}} = Conversations._unsafe_set_turn_session(c.turn, "late")
    assert {:error, :ownership_changed} = Conversations._unsafe_orphan_turn(c.turn, "old_machine")
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Turn, c.turn.id).status == "running"
  end

  test "session preparation and a late pre-start failure cannot change a successor", c do
    {next, _} = successor(c)
    assert {:error, :execution_fenced} = TurnMachine.session_plan(c.turn, nil)
    assert :ok = TurnMachine.fail_before_start(c.turn, c.conv.id, "spawn", "late failure", 1)
    assert Repo.get!(Conversation, c.conv.id).status == "running"
    assert Repo.get!(Conversation, c.conv.id).runtime_session_id == "original-session"
    assert Repo.get!(Turn, next.id).status == "running"
  end

  test "refused session preparation returns before command construction", c do
    successor(c)
    state = %{conversation_id: c.conv.id, runtime_session_id: nil, turn_execution: nil}

    assert ^state =
             Conversations.TurnLaunch.run(state, c.conv, c.turn, "late", nil, [], true, fn _,
                                                                                           _,
                                                                                           _ ->
               flunk("unexpected output")
             end)

    assert Repo.get!(Conversation, c.conv.id).status == "running"
  end
end
