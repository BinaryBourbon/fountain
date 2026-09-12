defmodule Fountain.Conversations.TurnExecutionLimitsTest do
  @moduledoc """
  The allowance a bounded turn is admitted under is resolved once, at
  registration, and frozen onto its journal row.

  The saved conversation allowance lives in `execution_allowances` (#1790), so
  these read it from there rather than from a column on the parent.
  """
  use Fountain.DataCase, async: false

  alias Fountain.Accounts

  alias Fountain.Conversations.{
    ExecutionAllowance,
    ExecutionGuard,
    ExecutionLimits,
    TurnExecution
  }

  setup do
    prior = Application.get_env(:fountain, :execution_limit_ceiling)
    on_exit(fn -> Application.put_env(:fountain, :execution_limit_ceiling, prior || %{}) end)
    Application.put_env(:fountain, :execution_limit_ceiling, %{})

    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conversation = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    now = DateTime.utc_now()

    turn =
      insert_turn(conversation, status: "running", started_at: DateTime.truncate(now, :second))

    %{user: user, sandbox: sandbox, conversation: conversation, turn: turn, now: now}
  end

  defp save_allowance(conversation_id, limits) do
    conversation_id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert!()
  end

  defp register(c, seconds) do
    ExecutionGuard._unsafe_register(
      c.turn.id,
      Ecto.UUID.generate(),
      DateTime.add(c.turn.started_at, seconds, :second),
      now: c.now
    )
  end

  describe "host_ceiling/0 and enforced_controls/1" do
    test "the ceiling is read per call, so an operator change reaches the next turn" do
      assert ExecutionLimits.host_ceiling() == %{}
      Application.put_env(:fountain, :execution_limit_ceiling, %{"wall_time_seconds" => 30})
      assert ExecutionLimits.host_ceiling() == %{"wall_time_seconds" => 30}
    end

    test "no control is enforced yet, and that is what refuses a configured limit" do
      assert ExecutionLimits.enforced_controls("claude") == []

      assert {:error, {:execution_limits_unsupported, ["wall_time_seconds"]}} =
               ExecutionLimits.require_controls(
                 %{"wall_time_seconds" => 30},
                 ExecutionLimits.enforced_controls("claude")
               )
    end
  end

  describe "the allowance is frozen onto the journal row" do
    test "with nothing configured the row records an empty allowance", c do
      assert {:ok, execution} = register(c, 60)
      assert execution.execution_limits == %{}
    end

    test "the saved conversation allowance is what a turn is admitted under", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 120})
      assert {:ok, execution} = register(c, 60)
      assert execution.execution_limits == %{"wall_time_seconds" => 120}
    end

    test "the account ceiling tightens the saved allowance", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 120})

      {:ok, _} =
        Accounts.update_execution_limits(c.user, %{wall_time_seconds: 45}, actor: "admin")

      assert {:ok, execution} = register(c, 40)
      assert execution.execution_limits == %{"wall_time_seconds" => 45}
    end

    test "the host ceiling tightens both", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 120})

      {:ok, _} =
        Accounts.update_execution_limits(c.user, %{wall_time_seconds: 90}, actor: "admin")

      Application.put_env(:fountain, :execution_limit_ceiling, %{"wall_time_seconds" => 20})
      assert {:ok, execution} = register(c, 15)
      assert execution.execution_limits == %{"wall_time_seconds" => 20}
    end

    test "the frozen allowance cannot be rewritten afterwards", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 120})
      {:ok, execution} = register(c, 60)

      refute TurnExecution.changeset(execution, %{execution_limits: %{"wall_time_seconds" => 1}}).valid?

      refute TurnExecution.changeset(execution, %{execution_limits: %{}}).valid?
    end

    test "a ceiling raised mid-conversation does not widen an admitted turn", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 30})
      {:ok, execution} = register(c, 30)
      assert execution.execution_limits == %{"wall_time_seconds" => 30}

      {:ok, _} =
        Accounts.update_execution_limits(c.user, %{wall_time_seconds: 600}, actor: "admin")

      assert Repo.get!(TurnExecution, execution.id).execution_limits == %{
               "wall_time_seconds" => 30
             }
    end
  end

  describe "the deadline is checked against the allowance, not trusted from the caller" do
    test "a deadline beyond the wall-clock allowance is refused, not clamped", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 30})

      assert {:error, {:execution_limits_widen, "wall_time_seconds"}} = register(c, 31)
      assert Repo.aggregate(TurnExecution, :count) == 0
    end

    test "a deadline exactly at the allowance is admitted", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 30})
      assert {:ok, _} = register(c, 30)
    end

    test "a shorter deadline than the allowance is admitted", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 300})
      assert {:ok, execution} = register(c, 10)
      assert execution.execution_limits == %{"wall_time_seconds" => 300}
    end

    test "a turn that never started cannot be bounded", c do
      save_allowance(c.conversation.id, %{"wall_time_seconds" => 30})
      c.turn |> change(started_at: nil) |> Repo.update!()

      assert {:error, :turn_not_started} =
               ExecutionGuard._unsafe_register(
                 c.turn.id,
                 Ecto.UUID.generate(),
                 DateTime.add(c.now, 10),
                 now: c.now
               )
    end
  end

  describe "Accounts.update_execution_limits/3" do
    test "sets, narrows and clears a ceiling, and audits the fields", c do
      assert {:ok, limited} =
               Accounts.update_execution_limits(c.user, %{wall_time_seconds: 60}, actor: "admin")

      assert limited.execution_limits == %{"wall_time_seconds" => 60}

      assert {:ok, cleared} = Accounts.update_execution_limits(limited, nil, actor: "admin")
      assert cleared.execution_limits == %{}

      actions =
        Repo.all(
          from a in Fountain.Audit.Event,
            where: a.user_id == ^c.user.id and a.action == "account.execution_limits_changed",
            select: a.metadata
        )

      assert length(actions) == 2
      assert Enum.any?(actions, &(&1["to"] == %{"wall_time_seconds" => 60}))
      # The trail names the fields, never a policy nobody can reconstruct.
      assert Enum.all?(actions, &(Map.keys(&1) |> Enum.sort() == ["from", "to"]))
    end

    test "an invalid ceiling is refused rather than stored", c do
      assert {:error, changeset} =
               Accounts.update_execution_limits(c.user, %{wall_time_seconds: -1}, actor: "admin")

      refute changeset.valid?
      assert Repo.reload!(c.user).execution_limits == %{}
    end
  end
end
