# The existing proof validates the dedicated local database before any writes.
Code.require_file("scripts/verify-turn-deadline-races.exs")
alias Fountain.Repo
alias Fountain.Conversations

alias Fountain.Conversations.{
  Conversation,
  Sandbox,
  TurnExecution,
  ExecutionGuard,
  ExecutionLimits
}

import Ecto.Query

{:ok, _} = Application.ensure_all_started(:mimic)
:ok = Mimic.copy(ExecutionLimits)
:ok = Mimic.set_mimic_global()
Mimic.stub(ExecutionLimits, :enforced_controls, fn _ -> ExecutionLimits.keys() end)

user =
  Repo.insert!(%Fountain.Accounts.User{
    email: "admission-race-#{Ecto.UUID.generate()}@example.test"
  })

fixture = fn ->
  sandbox =
    %Sandbox{}
    |> Sandbox.changeset(%{
      user_id: user.id,
      sprite_name: "local-admission-#{Ecto.UUID.generate()}",
      status: "ready"
    })
    |> Repo.insert!()

  conv =
    %Conversation{}
    |> Conversation.changeset(%{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "running",
      execution_limits: %{"wall_time_seconds" => 60}
    })
    |> Repo.insert!()

  attrs = %{
    conversation_id: conv.id,
    turn_number: 1,
    prompt: "local admission race; no provider I/O",
    status: "running",
    started_at: DateTime.utc_now() |> DateTime.truncate(:second)
  }

  {sandbox, conv, attrs}
end

for _ <- 1..20 do
  {sandbox, conv, attrs} = fixture.()

  results =
    DeadlineRace.concurrently([
      fn -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded) end,
      fn -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded) end
    ])

  [{:ok, turn}] = Enum.filter(results, &match?({:ok, _}, &1))
  [{:error, :execution_fenced}] = Enum.filter(results, &match?({:error, _}, &1))
  1 = Repo.aggregate(from(e in TurnExecution, where: e.conversation_id == ^conv.id), :count)
  execution = ExecutionGuard._unsafe_for_turn(turn.id)
  true = DateTime.compare(execution.deadline_at, DateTime.add(turn.started_at, 60)) == :eq
  {:ok, {:bounded, _}} = ExecutionGuard._unsafe_interrupt(conv.id)
  "stopped" = Repo.get!(TurnExecution, execution.id).state
end

cancellation =
  for _ <- 1..20 do
    {sandbox, conv, attrs} = fixture.()
    {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
    execution = ExecutionGuard._unsafe_for_turn(turn.id)

    [_claim, :ok] =
      DeadlineRace.concurrently([
        fn -> ExecutionGuard._unsafe_claim_spawn(execution.id) end,
        fn -> Conversations.ConversationServer.interrupt(conv.id) end
      ])

    execution = Repo.get!(TurnExecution, execution.id)

    case execution.state do
      "stopped" ->
        nil = execution.spawn_submitted_at
        "cancel_before_spawn"

      "awaiting_identity" ->
        false = is_nil(execution.spawn_submitted_at)

        {:ok, %{state: "ready"}} =
          ExecutionGuard._unsafe_bind_identity(
            execution.id,
            execution.connection_id,
            "fixture-late-identity"
          )

        {:ok, %{permitted: true, execution: claimed}} =
          ExecutionGuard._unsafe_claim_termination(execution.id)

        {:ok, %{state: "stopped"}} =
          ExecutionGuard._unsafe_record_termination(execution.id, claimed.attempt_id, :ok)

        "spawn_intent_before_cancel"
    end
  end

for _ <- 1..20 do
  {sandbox, conv, attrs} = fixture.()
  {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
  execution = ExecutionGuard._unsafe_for_turn(turn.id)
  {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

  {:ok, _} =
    ExecutionGuard._unsafe_bind_identity(
      execution.id,
      execution.connection_id,
      "fixture-original-session"
    )

  {:ok, {:bounded, _}} = ExecutionGuard._unsafe_interrupt(conv.id)

  [_deleted, {:ok, %{permitted: true, execution: claimed}}] =
    DeadlineRace.concurrently([
      fn -> Repo.delete!(conv) end,
      fn -> ExecutionGuard._unsafe_claim_termination(execution.id) end
    ])

  nil = Repo.get(Conversation, conv.id)
  true = claimed.sandbox_id == sandbox.id

  {:ok, %{execution: %{state: "submitted"}}} =
    ExecutionGuard._unsafe_complete(execution.id, "interrupted")

  {:ok, %{state: "stopped"}} =
    ExecutionGuard._unsafe_record_termination(execution.id, claimed.attempt_id, :ok)
end

IO.puts(
  "BOUNDED_LIFECYCLE_RACE_RESULT=" <>
    Jason.encode!(%{
      scope: "Dedicated local PostgreSQL; capabilities explicitly stubbed; no provider I/O",
      separate_database_connections: true,
      concurrent_admission_cases: 20,
      one_turn_and_journal_per_admission_race: true,
      cancellation_cases: 20,
      cancellation_outcomes: Enum.frequencies(cancellation),
      deletion_vs_cleanup_claim_cases: 20,
      original_cleanup_survives_parent_deletion: true,
      provider_operations: 0,
      confirmation_results: "synthetic fixture acknowledgments only"
    })
)
