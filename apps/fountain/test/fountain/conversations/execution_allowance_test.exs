defmodule Fountain.Conversations.ExecutionAllowanceTest do
  use Fountain.DataCase, async: true
  alias Fountain.{Accounts, Repo}
  alias Fountain.Accounts.User
  alias Fountain.Conversations.{Conversation, ExecutionGuard, TurnExecution}

  test "ordinary account changesets never accept operator ceilings" do
    attrs = %{execution_limits: %{wall_time_seconds: 999_999}}

    for changeset <- [
          User.registration_changeset(%User{}, attrs),
          User.oauth_registration_changeset(%User{}, attrs),
          User.principal_changeset(%User{}, attrs)
        ] do
      refute Map.has_key?(changeset.changes, :execution_limits)
    end
  end

  test "the dedicated operator setter validates, audits and can clear a ceiling" do
    user = insert_verified_user()
    assert {:error, _} = Accounts.update_execution_limits(user, %{wall_time_seconds: "60"})

    assert {:ok, limited} =
             Accounts.update_execution_limits(user, %{wall_time_seconds: 60}, actor: "admin")

    assert limited.execution_limits == %{"wall_time_seconds" => 60}
    assert {:ok, cleared} = Accounts.update_execution_limits(limited, nil, actor: "admin")
    assert cleared.execution_limits == %{}

    events =
      Repo.all(
        from e in Fountain.Audit.Event,
          where: e.user_id == ^user.id and e.action == "account.execution_limits_changed"
      )

    assert length(events) == 2
    assert Enum.any?(events, &(&1.metadata["to"] == %{"wall_time_seconds" => 60}))
  end

  test "conversation updates inherit omitted fields and cannot clear or widen limits" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        sandbox: sandbox,
        execution_limits: %{"wall_time_seconds" => 60, "max_model_turns" => 10}
      )

    assert {:ok, narrowed} =
             conv
             |> Conversation.changeset(%{execution_limits: %{wall_time_seconds: 30}})
             |> Repo.update()

    assert narrowed.execution_limits == %{"wall_time_seconds" => 30, "max_model_turns" => 10}

    assert {:ok, retained} =
             narrowed |> Conversation.changeset(%{execution_limits: nil}) |> Repo.update()

    assert retained.execution_limits == narrowed.execution_limits
    refute Conversation.changeset(narrowed, %{execution_limits: %{wall_time_seconds: 31}}).valid?
  end

  test "journal registration snapshots ceilings and refuses an extended deadline" do
    user = insert_verified_user()

    {:ok, user} =
      Accounts.update_execution_limits(user, %{wall_time_seconds: 30, max_model_turns: 5})

    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        sandbox: sandbox,
        status: "running",
        execution_limits: %{"wall_time_seconds" => 60, "max_model_turns" => 10}
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    turn = insert_turn(conv, status: "running", started_at: now)
    connection = Ecto.UUID.generate()

    assert {:error, {:execution_limits_widen, "wall_time_seconds"}} =
             ExecutionGuard._unsafe_register(turn.id, connection, DateTime.add(now, 31))

    assert {:ok, execution} =
             ExecutionGuard._unsafe_register(turn.id, connection, DateTime.add(now, 30))

    assert execution.execution_limits == %{"wall_time_seconds" => 30, "max_model_turns" => 5}
    {:ok, _} = Accounts.update_execution_limits(user, nil)

    assert {:ok, replay} =
             ExecutionGuard._unsafe_register(turn.id, connection, DateTime.add(now, 30))

    assert replay.execution_limits == execution.execution_limits
    refute TurnExecution.changeset(execution, %{execution_limits: %{}}).valid?
  end
end
