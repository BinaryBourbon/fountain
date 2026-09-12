# Validates the dedicated local database and supplies separate-connection barriers.
Code.require_file("scripts/verify-turn-deadline-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Conversation, ExecutionGuard, LogEvent, Sandbox, Turn}
import Ecto.Query

user =
  Repo.insert!(%Fountain.Accounts.User{
    email: "transcript-race-#{Ecto.UUID.generate()}@example.test"
  })

fixture = fn seconds ->
  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-transcript-#{Ecto.UUID.generate()}",
      status: "ready"
    })

  conv =
    Repo.insert!(%Conversation{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "running"
    })

  turn =
    Repo.insert!(%Turn{
      conversation_id: conv.id,
      turn_number: 1,
      prompt: "local transcript race",
      status: "running"
    })

  deadline = DateTime.add(DateTime.utc_now(), seconds)
  {:ok, execution} = ExecutionGuard._unsafe_register(turn.id, Ecto.UUID.generate(), deadline)
  {conv, turn, execution, deadline}
end

write = fn conv, turn ->
  Conversations.log!(%{
    conversation_id: conv.id,
    turn_id: turn.id,
    kind: "output",
    stream: "stdout",
    data: "fixture output"
  })
end

for _ <- 1..20 do
  {conv, turn, _, _} = fixture.(60)

  results =
    DeadlineRace.concurrently([
      fn -> Conversations._unsafe_record_turn_usage(turn, %{"input" => 7, "output" => 3}) end,
      fn -> Conversations._unsafe_record_turn_usage(turn, %{"input" => 7, "output" => 3}) end
    ])

  1 = Enum.count(results, &match?({:ok, _}, &1))
  1 = Enum.count(results, &match?({:error, :already_recorded}, &1))
  %{usage_input_tokens: 7, usage_output_tokens: 3} = Repo.get!(Conversation, conv.id)
end

for _ <- 1..20 do
  {conv, turn, _, _} = fixture.(60)

  [{:ok, _}, {:ok, _}] =
    DeadlineRace.concurrently([
      fn -> Conversations._unsafe_record_turn_usage(turn, %{"input" => 7, "output" => 3}) end,
      fn -> ExecutionGuard._unsafe_interrupt(conv.id) end
    ])

  %{usage_input_tokens: 7, usage_output_tokens: 3} = Repo.get!(Conversation, conv.id)
  %{status: "interrupted", usage: %{"input" => 7, "output" => 3}} = Repo.get!(Turn, turn.id)
end

output_results =
  for _ <- 1..20 do
    {conv, turn, _, _} = fixture.(60)

    [event, {:ok, _}] =
      DeadlineRace.concurrently([
        fn -> write.(conv, turn) end,
        fn -> ExecutionGuard._unsafe_interrupt(conv.id) end
      ])

    nil = write.(conv, turn)
    count = Repo.aggregate(from(e in LogEvent, where: e.turn_id == ^turn.id), :count)
    expected = if is_nil(event), do: 0, else: 1
    ^expected = count
    if is_nil(event), do: "cancel_first", else: "output_first"
  end

# The real output/stage writers must re-read the clock AFTER waiting on either
# parent or turn locks. A pre-dispatch actor check cannot satisfy this proof.
for operation <- [:output, :stage], table <- ["conversations", "turns"] do
  {conv, turn, _, deadline} = fixture.(2)
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
          :output -> write.(conv, turn)
          :stage -> Conversations.publish_stage(conv.id, "model", "done", %{turn_id: turn.id})
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
  nil = Task.await(writer)

  [%{kind: "stage", state: "failed", stage: "turn"}] =
    Repo.all(from e in LogEvent, where: e.turn_id == ^turn.id)

  %{status: "failed", limit_reason: "wall_time_limit"} = Repo.get!(Turn, turn.id)
end

IO.puts(
  "TRANSCRIPT_RACE_RESULT=" <>
    Jason.encode!(%{
      duplicate_usage: 20,
      usage_vs_cancellation: 20,
      output_vs_cancellation: 20,
      output_outcomes: Enum.frequencies(output_results),
      delayed_lock_cases: 4,
      delayed_tables: ["conversations", "turns"],
      delayed_operations: ["output", "model_stage"],
      provider_operations: 0,
      separate_database_connections: true,
      scope:
        "Local transcript arbitration and once-only accounting; no provider termination or billing proof"
    })
)
