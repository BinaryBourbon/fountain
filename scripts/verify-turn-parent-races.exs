# This prelude validates the dedicated local database and independent connections.
Code.require_file("scripts/verify-turn-deadline-races.exs")
alias Fountain.{Conversations, Repo}

alias Fountain.Conversations.{
  Conversation,
  Sandbox,
  Turn,
  TurnExecution,
  ExecutionGuard,
  ExecutionLimits
}

{:ok, _} = Application.ensure_all_started(:mimic)
:ok = Mimic.copy(ExecutionLimits)
:ok = Mimic.set_mimic_global()
Mimic.stub(ExecutionLimits, :enforced_controls, fn _ -> ExecutionLimits.keys() end)

user =
  Repo.insert!(%Fountain.Accounts.User{email: "parent-race-#{Ecto.UUID.generate()}@example.test"})

fixture = fn ->
  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-parent-#{Ecto.UUID.generate()}",
      status: "ready"
    })

  conv =
    Repo.insert!(%Conversation{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "idle",
      runtime_session_id: "original",
      execution_limits: %{"wall_time_seconds" => 60}
    })

  attrs = %{
    conversation_id: conv.id,
    turn_number: 1,
    prompt: "local parent fixture",
    status: "running",
    started_at: DateTime.utc_now() |> DateTime.truncate(:second)
  }

  {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
  {sandbox, conv, turn, ExecutionGuard._unsafe_for_turn(turn.id), attrs}
end

idle_results =
  for _ <- 1..20 do
    {sandbox, conv, turn, _, attrs} = fixture.()
    {:ok, _} = ExecutionGuard._unsafe_interrupt(conv.id)

    [{:ok, old}, {:ok, next}] =
      DeadlineRace.concurrently([
        fn -> Conversations._unsafe_idle_after_turn(turn) end,
        fn ->
          Conversations._unsafe_create_turn_on_sandbox(
            %{attrs | turn_number: 2},
            sandbox.id,
            :unbounded
          )
        end
      ])

    "running" = Repo.get!(Conversation, conv.id).status
    "running" = Repo.get!(Turn, next.id).status
    "active" = ExecutionGuard._unsafe_for_turn(next.id).state
    {:ok, %{applied: false}} = Conversations._unsafe_idle_after_turn(turn)
    if old.applied, do: "idle_before_admission", else: "admission_before_idle"
  end

session_results =
  for _ <- 1..20 do
    {_, conv, turn, _, _} = fixture.()

    [{:ok, report}, {:ok, _}] =
      DeadlineRace.concurrently([
        fn -> Conversations._unsafe_set_turn_session(turn, "accepted-before-cancel") end,
        fn -> ExecutionGuard._unsafe_interrupt(conv.id) end
      ])

    expected = if report.applied, do: "accepted-before-cancel", else: "original"
    ^expected = Repo.get!(Conversation, conv.id).runtime_session_id
    {:ok, %{applied: false}} = Conversations._unsafe_set_turn_session(turn, "too-late")
    ^expected = Repo.get!(Conversation, conv.id).runtime_session_id
    if report.applied, do: "session_before_cancel", else: "cancel_before_session"
  end

for _ <- 1..20 do
  {_, conv, turn, execution, _} = fixture.()
  {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

  [{:ok, _, _}, {:ok, _}] =
    DeadlineRace.concurrently([
      fn -> Conversations._unsafe_orphan_turn(turn, "lost_actor") end,
      fn -> Conversations._unsafe_record_turn_usage(turn, %{"input" => 7, "output" => 3}) end
    ])

  %{status: "failed", usage: %{"input" => 7}, orphaned_at: %DateTime{}} =
    Repo.get!(Turn, turn.id)

  %{status: "idle", usage_input_tokens: 7, usage_output_tokens: 3} =
    Repo.get!(Conversation, conv.id)

  %{state: "awaiting_identity", last_error: "spawn_unconfirmed"} =
    Repo.get!(TurnExecution, execution.id)
end

recovery_results =
  for _ <- 1..20 do
    {_, conv, turn, execution, _} = fixture.()
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    [recovery, {:ok, _}] =
      DeadlineRace.concurrently([
        fn -> Conversations._unsafe_orphan_turn(turn, "lost_actor") end,
        fn -> ExecutionGuard._unsafe_interrupt(conv.id) end
      ])

    "failed" = Repo.get!(Turn, turn.id).status

    %{state: "awaiting_identity", last_error: "spawn_unconfirmed"} =
      Repo.get!(TurnExecution, execution.id)

    if recovery == :noop, do: "cancel_before_recovery", else: "recovery_before_cancel"
  end

for operation <- [:session, :recovery], table <- ["conversations", "turns"] do
  {_, conv, turn, execution, _} = fixture.()
  deadline = DateTime.add(DateTime.utc_now(), 2)
  execution |> Ecto.Changeset.change(deadline_at: deadline) |> Repo.update!()
  owner = self()
  id = if table == "conversations", do: conv.id, else: turn.id

  holder =
    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(id)])
        send(owner, :locked)

        receive do
          :release -> :ok
        after
          10_000 -> raise "Lock holder timed out"
        end
      end)
    end)

  receive do
    :locked -> :ok
  after
    10_000 -> raise "Lock acquisition timed out"
  end

  writer =
    Task.async(fn ->
      Repo.checkout(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:writer_backend, backend})

        case operation do
          :session -> Conversations._unsafe_set_turn_session(turn, "too-late")
          :recovery -> Conversations._unsafe_orphan_turn(turn, "lost_actor")
        end
      end)
    end)

  backend =
    receive do
      {:writer_backend, backend} -> backend
    after
      1_000 -> raise "Writer checkout timed out"
    end

  waiting =
    Enum.reduce_while(1..100, false, fn _, _ ->
      case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
        [["Lock"]] ->
          {:halt, true}

        _ ->
          Process.sleep(5)
          {:cont, false}
      end
    end)

  true = waiting
  :lt = DateTime.compare(DateTime.utc_now(), deadline)
  Process.sleep(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 50)
  send(holder.pid, :release)
  Task.await(holder)
  result = Task.await(writer)

  case operation do
    :session -> {:ok, %{applied: false}} = result
    :recovery -> {:ok, %{limit_reason: "wall_time_limit"}, _} = result
  end

  %{status: "failed", limit_reason: "wall_time_limit"} = Repo.get!(Turn, turn.id)
  "original" = Repo.get!(Conversation, conv.id).runtime_session_id
end

IO.puts(
  "PARENT_RACE_RESULT=" <>
    Jason.encode!(%{
      late_idle_vs_admission: 20,
      idle_outcomes: Enum.frequencies(idle_results),
      session_vs_cancel: 20,
      session_outcomes: Enum.frequencies(session_results),
      recovery_vs_usage: 20,
      recovery_vs_cancel: 20,
      recovery_outcomes: Enum.frequencies(recovery_results),
      delayed_lock_cases: 4,
      delayed_tables: ["conversations", "turns"],
      separate_database_connections: true,
      provider_operations: 0,
      scope:
        "Local parent/session/recovery arbitration; capabilities stubbed only in this dedicated local proof"
    })
)
