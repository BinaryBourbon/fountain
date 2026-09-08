defmodule Fountain.Conversations.ReleaseFenceTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, ExecutionGuard, TurnExecution}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{conv: Repo.reload!(conv), sandbox: sandbox}
  end

  test "an absent actor does not authorize release of a running legacy turn", c do
    turn = insert_turn(c.conv, status: "running")
    assert {:error, :busy} = ConversationServer.release_conversation(c.conv.id)
    assert Conversations._unsafe_get_conversation!(c.conv.id).status == "idle"
    assert Repo.reload!(turn).status == "running"
  end

  for state <- ~w(active awaiting_identity ready submitted uncertain) do
    @state state
    test "release refuses #{@state} execution without changing it", c do
      execution = execution(c, @state)
      turn = Repo.get!(Conversations.Turn, execution.turn_id)
      assert is_nil(ConversationServer.whereis(c.conv.id))
      assert {:error, :busy} = ConversationServer.release_conversation(c.conv.id)
      assert Repo.reload!(execution) == execution
      assert Repo.reload!(turn) == turn
      assert Repo.reload!(c.conv) == c.conv
      assert Repo.reload!(c.sandbox) == c.sandbox
    end
  end

  test "confirmed cleanup permits release and later admission cannot revive the parent", c do
    execution = execution(c, "submitted")

    # Synthetic cleanup acknowledgment; no provider deletion is claimed.
    {:ok, _} =
      ExecutionGuard._unsafe_record_termination(execution.id, execution.attempt_id, :ok)

    assert :ok = ConversationServer.release_conversation(c.conv.id)
    assert Repo.reload!(c.conv).status == "terminated"
    assert Repo.reload!(c.sandbox) == c.sandbox

    attrs = %{
      conversation_id: c.conv.id,
      turn_number: 2,
      prompt: "too late",
      status: "running",
      started_at: DateTime.utc_now()
    }

    assert {:error, :not_running} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)
  end

  test "an unrelated co-tenant may keep working when this idle conversation releases", c do
    other =
      insert_conversation(user_id: c.conv.user_id, sandbox: c.sandbox, status: "running")

    turn = insert_turn(other, status: "running")
    other = Repo.reload!(other)
    assert :ok = ConversationServer.release_conversation(c.conv.id)
    assert Repo.reload!(other) == other
    assert Repo.reload!(turn) == turn
    assert Repo.reload!(c.sandbox) == c.sandbox
  end

  test "a deleted parent returns not_running", c do
    Repo.delete!(c.conv)
    assert {:error, :not_running} = ConversationServer.release_conversation(c.conv.id)
  end

  defp execution(c, state) do
    turn = insert_turn(c.conv, status: "running")

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    if state != "active" do
      {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

      if state != "awaiting_identity" do
        {:ok, _} =
          ExecutionGuard._unsafe_bind_identity(
            execution.id,
            execution.connection_id,
            "synthetic-release-command"
          )
      end

      {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)

      if state in ["submitted", "uncertain"] do
        {:ok, %{execution: claimed}} = ExecutionGuard._unsafe_claim_termination(execution.id)

        if state == "uncertain" do
          {:ok, _} =
            ExecutionGuard._unsafe_record_termination(
              execution.id,
              claimed.attempt_id,
              {:error, :timeout}
            )
        end
      end
    end

    result = Repo.get!(TurnExecution, execution.id)
    assert result.state == state
    result
  end
end
