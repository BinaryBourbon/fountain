# The inherited proof checks the dedicated local database before any writes.
Code.require_file("scripts/verify-provision-context-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ActorClaim, ActorOwnership, LogEvent, ProvisionContext, Sandbox}
import Ecto.Query

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "actor-owner-#{Ecto.UUID.generate()}@example.test"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-actor-#{Ecto.UUID.generate()}", status: "pending"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "pending"})
  {user, sandbox, parent}
end

for replay? <- [false, true], _ <- 1..10 do
  {user, sandbox, parent} = fixture.()
  first = Ecto.UUID.generate()
  second = if replay?, do: first, else: Ecto.UUID.generate()
  results = DeadlineRace.concurrently([
    fn -> ActorOwnership.claim(user.id, parent.id, sandbox.id, first) end,
    fn -> ActorOwnership.claim(user.id, parent.id, sandbox.id, second) end
  ])

  if replay? do
    true = Enum.all?(results, &match?({:ok, %ActorClaim{id: ^first}}, &1))
  else
    1 = Enum.count(results, &match?({:ok, %ActorClaim{}}, &1))
    1 = Enum.count(results, &(&1 == {:error, :actor_owned}))
  end

  1 = Repo.aggregate(from(a in ActorClaim, where: a.conversation_id == ^parent.id), :count)
end

for first_operation <- [:publication, :handoff] do
  {user, sandbox, parent} = fixture.()
  # Reattach handoff is valid only after provisioning has completed.
  {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
  original = Ecto.UUID.generate()
  replacement = Ecto.UUID.generate()
  {:ok, _} = ActorOwnership.claim(user.id, parent.id, sandbox.id, original)
  state = %{user_id: user.id, conversation_id: parent.id, sandbox_id: sandbox.id, actor_claim: original}
  context = ProvisionContext.new(parent, sandbox, original)
  owner = self()

  handoff = fn ->
    :ok = ActorOwnership.finish(state, fn -> :ok end)
    {:ok, _} = ActorOwnership.claim(user.id, parent.id, sandbox.id, replacement)
    :ok
  end

  publication = fn -> ProvisionContext.stage(context, "setup", "done") end

  holder = Task.async(fn ->
    Repo.transaction(fn ->
      result = if first_operation == :publication, do: publication.(), else: handoff.()
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:holder, self(), backend})
      receive do
        :commit -> result
      after
        5_000 -> raise "Actor handoff barrier timed out"
      end
    end)
  end)

  holder_backend = receive do
    {:holder, pid, backend} when pid == holder.pid -> backend
  after
    5_000 -> raise "Actor holder checkout timed out"
  end

  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:waiter, self(), backend})
      if first_operation == :publication, do: handoff.(), else: publication.()
    end)
  end)

  waiter_backend = receive do
    {:waiter, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "Actor waiter checkout timed out"
  end

  true = holder_backend != waiter_backend
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)

  send(holder.pid, :commit)
  {:ok, _} = Task.await(holder, 10_000)
  result = Task.await(waiter, 10_000)
  expected_events = if first_operation == :publication, do: 1, else: 0
  true = result == if(first_operation == :publication, do: :ok, else: nil)
  ^expected_events = Repo.aggregate(from(e in LogEvent, where: e.conversation_id == ^parent.id), :count)
  "stopped" = Repo.get!(ActorClaim, original).state
  "active" = Repo.get!(ActorClaim, replacement).state
  nil = ProvisionContext.output(context, "setup", "late predecessor output")
end

# Raw SQL cannot rewrite a claim's identity or resurrect its terminal state.
{user, sandbox, parent} = fixture.()
id = Ecto.UUID.generate()
{:ok, _} = ActorOwnership.claim(user.id, parent.id, sandbox.id, id)
for field <- ~w(id user_id conversation_id sandbox_id) do
  try do
    Repo.transaction(fn ->
      Repo.query!("UPDATE conversation_actor_claims SET #{field} = $1 WHERE id = $2", [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(id)])
    end)
    raise "Actor identity update was accepted"
  rescue
    error in Postgrex.Error -> :raise_exception = error.postgres.code
  end
end
:ok = ActorOwnership.finish(%{user_id: user.id, conversation_id: parent.id, sandbox_id: sandbox.id, actor_claim: id}, fn -> :ok end)
try do
  Repo.transaction(fn ->
    Repo.query!("UPDATE conversation_actor_claims SET state = 'active' WHERE id = $1", [Ecto.UUID.dump!(id)])
  end)
  raise "Retired actor claim was resurrected"
rescue
  error in Postgrex.Error -> :raise_exception = error.postgres.code
end
"stopped" = Repo.get!(ActorClaim, id).state

IO.puts("ACTOR_OWNERSHIP_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true,
  duplicate_claim_cases: 10,
  same_claim_replay_cases: 10,
  forced_same_machine_handoff_waits: 2,
  predecessor_publication_serialized: true,
  raw_sql_immutability_checks: 5,
  provider_operations: 0,
  scope: "Local actor-claim arbitration and same-machine publication ordering; not abandoned-claim recovery, complete actor fencing or live provider behavior"
}))
