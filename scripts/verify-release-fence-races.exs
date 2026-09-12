# The prelude refuses non-test/non-local databases and verifies independent connections.
Code.require_file("scripts/verify-turn-deadline-races.exs")
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Conversation, ExecutionGuard, ExecutionLimits, Sandbox, Turn}

{:ok, _} = Application.ensure_all_started(:mimic)
:ok = Mimic.copy(ExecutionLimits)
:ok = Mimic.set_mimic_global()
Mimic.stub(ExecutionLimits, :enforced_controls, fn _ -> ExecutionLimits.keys() end)

user = Repo.insert!(%Fountain.Accounts.User{email: "release-race-#{Ecto.UUID.generate()}@example.test"})

fixture = fn ->
  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-release-#{Ecto.UUID.generate()}",
      status: "ready"
    })

  conv =
    Repo.insert!(%Conversation{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "idle",
      execution_limits: %{"wall_time_seconds" => 60}
    })

  attrs = %{
    conversation_id: conv.id,
    turn_number: 1,
    prompt: "local release proof",
    status: "running",
    started_at: DateTime.utc_now() |> DateTime.truncate(:second)
  }

  {sandbox, conv, attrs}
end

admission_outcomes =
  for _ <- 1..20 do
    {sandbox, conv, attrs} = fixture.()

    [release, admission] =
      DeadlineRace.concurrently([
        fn -> Conversations._unsafe_release_conversation(conv.id) end,
        fn -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded) end
      ])

    case {release, admission} do
      {:ok, {:error, :not_running}} ->
        "terminated" = Repo.get!(Conversation, conv.id).status
        [] = Conversations._unsafe_list_turns(conv.id)
        "release_before_admission"

      {{:error, :busy}, {:ok, turn}} ->
        "running" = Repo.get!(Conversation, conv.id).status
        "running" = Repo.get!(Turn, turn.id).status
        "active" = ExecutionGuard._unsafe_for_turn(turn.id).state
        {:ok, _} = ExecutionGuard._unsafe_interrupt(conv.id)
        "admission_before_release"
    end
  end

for _ <- 1..20 do
  {sandbox, conv, attrs} = fixture.()
  {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
  execution = ExecutionGuard._unsafe_for_turn(turn.id)
  {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

  [{:error, :busy}, {:ok, _, _}] =
    DeadlineRace.concurrently([
      fn -> Conversations._unsafe_release_conversation(conv.id) end,
      fn -> Conversations._unsafe_orphan_turn(turn, "local_release_race") end
    ])

  "awaiting_identity" = ExecutionGuard._unsafe_for_turn(turn.id).state
  "idle" = Repo.get!(Conversation, conv.id).status
  {:error, :busy} = Conversations._unsafe_release_conversation(conv.id)
end

cleanup_outcomes =
  for _ <- 1..20 do
    {sandbox, conv, attrs} = fixture.()
    {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
    execution = ExecutionGuard._unsafe_for_turn(turn.id)
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(
        execution.id,
        execution.connection_id,
        "synthetic-release-command"
      )

    {:ok, _} = ExecutionGuard._unsafe_interrupt(conv.id)
    {:ok, %{execution: claimed}} = ExecutionGuard._unsafe_claim_termination(execution.id)

    # This is a synthetic acknowledgment, not provider termination evidence.
    [release, {:ok, _}] =
      DeadlineRace.concurrently([
        fn -> Conversations._unsafe_release_conversation(conv.id) end,
        fn -> ExecutionGuard._unsafe_record_termination(execution.id, claimed.attempt_id, :ok) end
      ])

    "stopped" = ExecutionGuard._unsafe_for_turn(turn.id).state

    case release do
      :ok ->
        "terminated" = Repo.get!(Conversation, conv.id).status
        "cleanup_before_release"

      {:error, :busy} ->
        "running" = Repo.get!(Conversation, conv.id).status
        :ok = Conversations._unsafe_release_conversation(conv.id)
        "release_before_cleanup"
    end
  end

IO.puts("RELEASE_RACE_RESULT=" <> Jason.encode!(%{
  scope: "Local release/admission/recovery/cleanup arbitration; synthetic identities and acknowledgments",
  release_vs_admission: 20,
  admission_outcomes: Enum.frequencies(admission_outcomes),
  release_vs_orphan_recovery: 20,
  release_vs_cleanup_ack: 20,
  cleanup_outcomes: Enum.frequencies(cleanup_outcomes),
  separate_database_connections: true,
  provider_operations: 0
}))
