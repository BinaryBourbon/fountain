# The inherited proof checks the dedicated local database before any writes.
Code.require_file("scripts/verify-turn-deadline-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{PromptDelivery, PromptWake, PromptWakeRequest}

fixture = fn ->
  user = Fountain.Factory.insert_verified_user(email: "wake-race-#{Ecto.UUID.generate()}@example.test")
  sandbox = Fountain.Factory.insert_sandbox(user_id: user.id, status: "ready", sprite_name: "local-wake-#{Ecto.UUID.generate()}")
  parent = Fountain.Factory.insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
  {:ok, receipt} = Repo.transaction(fn ->
    {:ok, receipt} = PromptDelivery.submit(user.id, parent.id, "local saved wake", [])
    PromptWake.save!(parent, receipt)
    receipt
  end)
  # The real wake returns :no_agent before any provider query or operation.
  true = is_nil(parent.agent_id)
  {user, sandbox, parent, receipt}
end

for _ <- 1..10 do
  {_, _, _, receipt} = fixture.()
  [:ok, :ok] = DeadlineRace.concurrently([
    fn -> PromptWake.deliver(receipt) end,
    fn -> PromptWake.deliver(receipt) end
  ])
  request = Repo.get!(PromptWakeRequest, receipt.id)
  "returned" = request.state
  true = not is_nil(request.started_at)
  true = not is_nil(request.returned_at)
  "refused" = Repo.reload!(receipt).state
  :ok = PromptWake.deliver(receipt)
  true = Repo.reload!(request).started_at == request.started_at
end

# Make the dispatcher wait on an actual second database connection. Its saved
# snapshot must not authorize wake after cancellation, binding transfer or expiry.
for operation <- [:cancel, :move, :expire] do
  {user, sandbox, parent, receipt} = fixture.()
  destination = Fountain.Factory.insert_sandbox(user_id: user.id, status: "ready")
  owner = self()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      for key <- Enum.sort(Enum.uniq(Enum.map([sandbox.id, destination.id], &:erlang.phash2/1))) do
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, key])
      end
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:holder, self(), backend})
      receive do
        :settle -> :ok
      after
        5_000 -> raise "Wake holder barrier timed out"
      end
      case operation do
        :cancel -> {:ok, _} = PromptDelivery.refuse(user.id, parent.id, receipt.id, "cancelled")
        :move -> {:ok, _} = Conversations.update_conversation(parent, %{sandbox_id: destination.id})
        :expire -> receipt |> Ecto.Changeset.change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()
      end
    end)
  end)
  holder_backend = receive do
    {:holder, pid, backend} when pid == holder.pid -> backend
  after
    5_000 -> raise "Wake holder checkout timed out"
  end
  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:waiter, self(), backend})
      PromptWake.deliver(receipt)
    end)
  end)
  waiter_backend = receive do
    {:waiter, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "Wake waiter checkout timed out"
  end
  true = holder_backend != waiter_backend
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  send(holder.pid, :settle)
  {:ok, _} = Task.await(holder, 10_000)
  :ok = Task.await(waiter, 10_000)
  %PromptWakeRequest{state: "requested", started_at: nil} = Repo.get!(PromptWakeRequest, receipt.id)
end

{_, _, _, receipt} = fixture.()
:ok = PromptWake.deliver(receipt)
for field <- ~w(id user_id conversation_id sandbox_id) do
  try do
    Repo.transaction(fn ->
      Repo.query!("UPDATE prompt_wake_requests SET #{field} = $1 WHERE id = $2", [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(receipt.id)])
    end)
    raise "Wake identity update was accepted"
  rescue
    error in Postgrex.Error -> :raise_exception = error.postgres.code
  end
end
for assignment <- ["state = 'requested', started_at = NULL, returned_at = NULL", "started_at = started_at + interval '1 second'", "returned_at = returned_at + interval '1 second'"] do
  try do
    Repo.transaction(fn ->
      Repo.query!("UPDATE prompt_wake_requests SET #{assignment} WHERE id = $1", [Ecto.UUID.dump!(receipt.id)])
    end)
    raise "Wake invocation history was rewritten"
  rescue
    error in Postgrex.Error -> :raise_exception = error.postgres.code
  end
end

IO.puts("PROMPT_WAKE_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true,
  duplicate_wake_cases: 10,
  forced_cancellation_transfer_expiry_waits: 3,
  raw_sql_identity_history_checks: 7,
  provider_operations: 0,
  scope: "Durable prompt wake invocation arbitration; not abandoned invocation/actor recovery or live provider behavior"
}))
