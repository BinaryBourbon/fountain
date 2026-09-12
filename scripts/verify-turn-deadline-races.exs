alias Fountain.Repo
alias Fountain.Conversations.{Conversation, Sandbox, Turn, TurnExecution, ExecutionGuard}
import Ecto.Query
config = Repo.config()
url = URI.parse(config[:url] || "")
host = config[:hostname] || url.host
database = config[:database] || String.trim_leading(url.path || "", "/")

if Mix.env() != :test or host not in ["localhost", "127.0.0.1"] or
     not String.starts_with?(database, "fountain_deadline_races_"),
   do: raise("This proof requires a dedicated local fountain_deadline_races_* database")

Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

defmodule DeadlineRace do
  def concurrently(functions) do
    owner = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          Fountain.Repo.checkout(fn ->
            %{rows: [[backend]]} = Fountain.Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:ready, self(), backend})

            receive do
              :go -> fun.()
            after
              10_000 -> raise "Barrier timed out"
            end
          end)
        end)
      end)

    participants =
      Enum.map(tasks, fn task ->
        receive do
          {:ready, pid, backend} when pid == task.pid -> {pid, backend}
        after
          10_000 -> raise "Database checkout timed out"
        end
      end)

    if MapSet.size(MapSet.new(Enum.map(participants, &elem(&1, 1)))) != length(functions),
      do: raise("The race did not use independent database connections")

    Enum.each(participants, fn {pid, _} -> send(pid, :go) end)
    Enum.map(tasks, &Task.await(&1, 15_000))
  end
end

user =
  Repo.insert!(%Fountain.Accounts.User{
    email: "deadline-race-#{Ecto.UUID.generate()}@example.test"
  })

results =
  for _ <- 1..20 do
    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        user_id: user.id,
        sprite_name: "local-database-fixture-#{Ecto.UUID.generate()}",
        status: "ready"
      })
      |> Repo.insert!()

    conv =
      %Conversation{}
      |> Conversation.changeset(%{
        user_id: user.id,
        sandbox_id: sandbox.id,
        runtime: "claude",
        status: "running"
      })
      |> Repo.insert!()

    turn =
      %Turn{}
      |> Turn.changeset(%{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "local database race fixture; no provider execution",
        status: "running"
      })
      |> Repo.insert!()

    now = DateTime.utc_now()
    deadline = DateTime.add(now, 60)
    connection = Ecto.UUID.generate()
    {:ok, execution} = ExecutionGuard._unsafe_register(turn.id, connection, deadline)
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(execution.id, connection, "controlled-fixture")

    DeadlineRace.concurrently([
      fn -> ExecutionGuard._unsafe_complete(execution.id, "completed", now: now) end,
      fn -> ExecutionGuard._unsafe_expire(execution.id, now: deadline) end
    ])

    execution = Repo.get!(TurnExecution, execution.id)
    turn = Repo.get!(Turn, turn.id)

    case {execution.state, turn.status} do
      {"completed", "completed"} ->
        nil = execution.deadline_event_id
        {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(execution.id)
        "completion_won"

      {"ready", "failed"} ->
        event = Repo.get!(Fountain.Conversations.LogEvent, execution.deadline_event_id)
        "failed" = event.state
        "wall_time_limit" = Jason.decode!(event.data)["stop_reason"]

        # Two late publishers share the same committed deadline outcome, even
        # though both ask for success on independent database connections.
        [first, second] =
          DeadlineRace.concurrently([
            fn ->
              Fountain.Conversations.publish_stage(conv.id, "turn", "done", %{turn_id: turn.id})
            end,
            fn ->
              Fountain.Conversations.publish_stage(conv.id, "turn", "done", %{turn_id: turn.id})
            end
          ])

        true = first.id == event.id and second.id == event.id

        1 =
          Repo.aggregate(
            from(e in Fountain.Conversations.LogEvent, where: e.turn_id == ^turn.id),
            :count
          )

        1 =
          Repo.aggregate(
            from(j in Oban.Job,
              where:
                j.worker == "Fountain.Workers.TurnDeadlineNotification" and
                  fragment("?->>'event_id'", j.args) == ^to_string(event.id)
            ),
            :count
          )

        claims =
          DeadlineRace.concurrently([
            fn -> ExecutionGuard._unsafe_claim_termination(execution.id) end,
            fn -> ExecutionGuard._unsafe_claim_termination(execution.id) end
          ])

        [%{execution: claimed}] =
          for {:ok, %{permitted: true} = permission} <- claims, do: permission

        [{:error, :not_ready}] = Enum.filter(claims, &match?({:error, _}, &1))

        {:ok, %{state: "uncertain"}} =
          ExecutionGuard._unsafe_record_termination(claimed.id, claimed.attempt_id, :lost_reply)

        {:error, :not_ready} = ExecutionGuard._unsafe_claim_termination(claimed.id)

        {:ok, %{turn: %{status: "failed"}}} =
          ExecutionGuard._unsafe_complete(claimed.id, "completed", now: DateTime.add(deadline, 1))

        "expiry_won"

      _ ->
        raise "Completion and termination were not mutually exclusive"
    end
  end

# A caller can reach the journal before its deadline, then wait behind a lock
# until after it. Authorization must use the time after acquiring the lock.
for lock_table <- ["conversations", "turns"] do
  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-lock-fixture-#{Ecto.UUID.generate()}",
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
      prompt: "local lock fixture",
      status: "running"
    })

  owner = self()
  lock_id = if lock_table == "conversations", do: conv.id, else: turn.id
  deadline = DateTime.add(DateTime.utc_now(), 2, :second)
  {:ok, execution} = ExecutionGuard._unsafe_register(turn.id, Ecto.UUID.generate(), deadline)

  holder =
    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT id FROM #{lock_table} WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(lock_id)
        ])

        send(owner, :locked)

        receive do
          :release -> :ok
        after
          10_000 -> raise "Lock release timed out"
        end
      end)
    end)

  receive do
    :locked -> :ok
  after
    10_000 -> raise "Lock acquisition timed out"
  end

  claim =
    Task.async(fn ->
      Repo.checkout(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:claim_backend, backend})
        ExecutionGuard._unsafe_claim_spawn(execution.id)
      end)
    end)

  backend =
    receive do
      {:claim_backend, backend} -> backend
    after
      1_000 -> raise "Claim checkout timed out"
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
  {:error, :deadline_expired} = Task.await(claim)
  true = is_nil(Repo.get!(TurnExecution, execution.id).spawn_submitted_at)
end

IO.puts(
  "DEADLINE_RACE_RESULT=" <>
    Jason.encode!(%{
      cases: length(results),
      outcomes: Enum.frequencies(results),
      separate_database_connections: true,
      provider_operations: 0,
      lock_wait_cannot_extend_deadline: true,
      delayed_lock_tables: ["conversations", "turns"],
      deadline_event_reuse_cases: Enum.count(results, &(&1 == "expiry_won")),
      scope: "Local PostgreSQL arbitration, event durability and write permissions only"
    })
)
