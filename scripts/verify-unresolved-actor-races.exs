# Inherited proofs check the dedicated local database before any writes.
Code.require_file("scripts/verify-actor-ownership-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ActorClaim, ActorOwnership, Conversation, Sandbox}
import Ecto.Query

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "unresolved-actor-#{Ecto.UUID.generate()}@example.test"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-unresolved-#{Ecto.UUID.generate()}", status: "pending"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "pending"})
  {user, sandbox, parent}
end

for status <- ~w(pending starting), _ <- 1..10 do
  {user, sandbox, parent} = fixture.()
  original = Ecto.UUID.generate()
  {:ok, claim} = ActorOwnership.claim(user.id, parent.id, sandbox.id, original)
  {:ok, _} = Conversations.update_sandbox(sandbox, %{status: status})
  state = %{user_id: user.id, conversation_id: parent.id, sandbox_id: sandbox.id, actor_claim: original}
  [:ok, result] = DeadlineRace.concurrently([
    fn -> ActorOwnership.finish(state, fn -> :ok end) end,
    fn -> ActorOwnership.claim(user.id, parent.id, sandbox.id, Ecto.UUID.generate()) end
  ])
  true = result in [{:error, :actor_owned}, {:error, :provisioning_unresolved}]
  "stopped" = Repo.reload!(claim).state
  1 = Repo.aggregate(from(a in ActorClaim, where: a.sandbox_id == ^sandbox.id), :count)
  ^status = Repo.reload!(sandbox).status
end

# Per-parent uniqueness alone cannot stop two parents creating the same pending
# machine. The machine lock and retained history must arbitrate those too.
for _ <- 1..10 do
  {user, sandbox, first} = fixture.()
  # Public attach already refuses pending machines. Model conflicting saved
  # bindings directly to prove the startup guard does not rely on that door.
  second = Repo.insert!(%Conversation{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "pending"})
  results = DeadlineRace.concurrently(Enum.map([first, second], fn parent ->
    fn -> ActorOwnership.claim(user.id, parent.id, sandbox.id, Ecto.UUID.generate()) end
  end))
  1 = Enum.count(results, &match?({:ok, %ActorClaim{}}, &1))
  1 = Enum.count(results, &(&1 == {:error, :provisioning_unresolved}))
  1 = Repo.aggregate(from(a in ActorClaim, where: a.sandbox_id == ^sandbox.id), :count)
end

# Force readiness to commit while startup waits with an older pending snapshot.
{_user, sandbox, parent} = fixture.()
owner = self()
holder = Task.async(fn ->
  Repo.transaction(fn ->
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox.id)])
    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:holder, self(), backend})
    receive do
      :commit -> :ok
    after
      5_000 -> raise "Readiness holder barrier timed out"
    end
  end)
end)
holder_backend = receive do
  {:holder, pid, backend} when pid == holder.pid -> backend
 after
  5_000 -> raise "Readiness checkout timed out"
end
waiter = Task.async(fn ->
  Repo.checkout(fn ->
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:waiter, self(), backend})
    # This fixture supplies an incarnation ID to avoid starting an unrelated
    # watchdog for the short-lived proof task. Claim arbitration is real.
    state = %{conversation_id: parent.id, sandbox_id: sandbox.id, actor_claim: Ecto.UUID.generate()}
    ActorOwnership.start(state, parent, sandbox, 30_000)
  end)
end)
waiter_backend = receive do
  {:waiter, pid, backend} when pid == waiter.pid -> backend
 after
  5_000 -> raise "Startup checkout timed out"
end
true = holder_backend != waiter_backend
true = Enum.reduce_while(1..200, false, fn _, _ ->
  case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
    [["Lock"]] -> {:halt, true}
    _ -> Process.sleep(5); {:cont, false}
  end
end)
send(holder.pid, :commit)
{:ok, :ok} = Task.await(holder, 10_000)
{:ok, state, authorized_parent, authorized_machine} = Task.await(waiter, 10_000)
true = authorized_parent.id == parent.id
"ready" = authorized_machine.status
"pending" = sandbox.status
:ok = ActorOwnership.finish(state, fn -> :ok end)

IO.puts("UNRESOLVED_ACTOR_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true,
  shutdown_successor_claim_races: 20,
  shared_pending_machine_claim_races: 10,
  forced_readiness_snapshot_waits: 1,
  provider_operations: 0,
  scope: "Unresolved provisioning startup refusal and locked snapshot selection; not provider reconciliation or live recovery"
}))
