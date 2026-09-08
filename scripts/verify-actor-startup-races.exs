# The inherited launch proof enforces the dedicated local database boundary and
# provides barriers that verify distinct PostgreSQL backend connections.
Code.require_file("scripts/verify-actor-launch-races.exs")
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ActorStartup, ActorStartups, ActorOwnership, LogEvent, Sandbox}
import Ecto.Query

fixture = fn seconds ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "startup-#{Ecto.UUID.generate()}@example.test", comped: true})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "startup-#{Ecto.UUID.generate()}", status: "ready"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
  id = Ecto.UUID.generate()
  {:ok, claim} = ActorOwnership.claim(user.id, parent.id, sandbox.id, id)
  startup = Repo.insert!(%ActorStartup{id: id, actor_claim_id: id, user_id: user.id, conversation_id: parent.id,
    sandbox_id: sandbox.id, deadline_at: DateTime.add(DateTime.utc_now(), seconds)})
  state = %{user_id: user.id, conversation_id: parent.id, sandbox_id: sandbox.id, actor_claim: id}
  %{user: user, parent: parent, sandbox: sandbox, claim: claim, startup: startup, state: state}
end

results = for offset <- [60, -1], _ <- 1..10 do
  c = fixture.(offset)
  [completed, expired] = LaunchRace.concurrently([
    fn -> ActorStartups.complete(c.state) end,
    fn -> ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id) end
  ])
  saved = Repo.reload!(c.startup)
  case saved.state do
    "completed" ->
      :ok = completed
      true = expired in [{:ok, :settled}, {:error, :deadline_not_reached}]
      0 = Repo.aggregate(from(e in LogEvent, where: e.conversation_id == ^c.parent.id), :count)
    "expired" ->
      {:error, :startup_expired} = completed
      {:ok, :expired} = expired
      1 = Repo.aggregate(from(e in LogEvent, where: e.conversation_id == ^c.parent.id), :count)
  end
  "ready" = Repo.reload!(c.sandbox).status
  true = saved.deadline_at == c.startup.deadline_at
  saved
end
10 = Enum.count(results, &(&1.state == "completed"))
10 = Enum.count(results, &(&1.state == "expired"))

for _ <- 1..20 do
  c = fixture.(-1)
  [:ok, {:ok, :expired}] = LaunchRace.concurrently([
    fn -> ActorOwnership.finish(c.state, fn -> :ok end) end,
    fn -> ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id) end
  ])
  "active" = Repo.reload!(c.claim).state
  "expired" = Repo.reload!(c.startup).state
  false = ActorOwnership.current?(c.state)
  {:error, :actor_owned} = ActorOwnership.claim(c.user.id, c.parent.id, c.sandbox.id, Ecto.UUID.generate())
end

# Completion must sample the clock after its original parent lock is acquired.
c = fixture.(1)
owner = self()
holder = Task.async(fn ->
  Repo.transaction(fn ->
    Repo.one!(from p in Conversations.Conversation, where: p.id == ^c.parent.id, lock: "FOR UPDATE")
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:holder, self(), backend})
    receive do
      :release -> :ok
    after
      5_000 -> raise "Startup holder timed out"
    end
  end)
end)
holder_backend = receive do
  {:holder, pid, backend} when pid == holder.pid -> backend
end
waiter = Task.async(fn ->
  Repo.checkout(fn ->
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:waiter, self(), backend})
    ActorStartups.complete(c.state)
  end)
end)
waiter_backend = receive do
  {:waiter, pid, backend} when pid == waiter.pid -> backend
end
true = holder_backend != waiter_backend
true = Enum.reduce_while(1..200, false, fn _, _ ->
  case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
    [["Lock"]] -> {:halt, true}
    _ -> Process.sleep(5); {:cont, false}
  end
end)
Process.sleep(max(DateTime.diff(c.startup.deadline_at, DateTime.utc_now(), :millisecond), 0) + 5)
send(holder.pid, :release)
{:ok, :ok} = Task.await(holder, 10_000)
{:error, :startup_expired} = Task.await(waiter, 10_000)
"expired" = Repo.reload!(c.startup).state

for {field, value} <- [{"deadline_at", "deadline_at + interval '1 hour'"}, {"user_id", "gen_random_uuid()"}, {"state", "'starting'"}] do
  try do
    Repo.transaction(fn ->
      Repo.query!("UPDATE actor_startups SET #{field} = #{value} WHERE id = $1", [Ecto.UUID.dump!(c.startup.id)])
    end)
    raise "Startup #{field} was rewritten"
  rescue
    error in Postgrex.Error -> :raise_exception = error.postgres.code
  end
end

IO.puts("ACTOR_STARTUP_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true, completion_expiry_races: 20,
  completed_outcomes: 10, expired_outcomes: 10, teardown_expiry_races: 20,
  forced_completion_deadline_waits: 1, sql_immutability_checks: 3,
  provider_operations: 0,
  scope: "First reconnect outcome and timeout ownership; not abandoned-worker reconciliation or provider-operation recovery"
}))

# Each later attempt has its own identity; old completed outcomes never select
# or settle the new attempt when watchdogs race completion or teardown.
repeat_fixture = fn seconds ->
  c = fixture.(60)
  :ok = ActorStartups.complete(c.state)
  first = Repo.reload!(c.startup)
  attempt = Repo.insert!(%ActorStartup{id: Ecto.UUID.generate(), actor_claim_id: c.claim.id,
    user_id: c.user.id, conversation_id: c.parent.id, sandbox_id: c.sandbox.id,
    deadline_at: DateTime.add(DateTime.utc_now(), seconds)})
  %{c | startup: attempt, state: Map.put(c.state, :actor_startup_id, attempt.id)}
  |> Map.put(:first, first)
end
for seconds <- [60, -1], _ <- 1..10 do
  c = repeat_fixture.(seconds)
  [completed, expired, old_watchdog] = LaunchRace.concurrently([
    fn -> ActorStartups.complete(c.state) end,
    fn -> ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id, c.startup.id) end,
    fn -> ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id, c.first.id) end
  ])
  {:ok, :settled} = old_watchdog
  true = Repo.reload!(c.first) == c.first
  case Repo.reload!(c.startup).state do
    "completed" ->
      :ok = completed
      true = expired in [{:ok, :settled}, {:error, :deadline_not_reached}]
    "expired" ->
      {:error, :startup_expired} = completed
      {:ok, :expired} = expired
      false = ActorOwnership.current?(c.state)
  end
end
for _ <- 1..20 do
  c = repeat_fixture.(-1)
  [:ok, {:ok, :expired}] = LaunchRace.concurrently([
    fn -> ActorOwnership.finish(c.state, fn -> :ok end) end,
    fn -> ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id, c.startup.id) end
  ])
  true = Repo.reload!(c.first) == c.first
  "active" = Repo.reload!(c.claim).state
  "expired" = Repo.reload!(c.startup).state
  false = ActorOwnership.current?(c.state)
end
c = repeat_fixture.(60)
try do
  Repo.transaction(fn ->
    Repo.query!("UPDATE actor_startups SET actor_claim_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(c.startup.id)])
  end)
  raise "Attempt was reassigned to another actor"
rescue
  error in Postgrex.Error -> :raise_exception = error.postgres.code
end
try do
  Repo.transaction(fn ->
    Repo.insert!(%ActorStartup{id: Ecto.UUID.generate(), actor_claim_id: c.claim.id,
      user_id: c.user.id, conversation_id: c.parent.id, sandbox_id: c.sandbox.id,
      deadline_at: DateTime.add(DateTime.utc_now(), 60)})
  end)
  raise "Two pending attempts were accepted for one actor"
rescue
  _ in Ecto.ConstraintError -> :ok
end
IO.puts("REPEAT_RECONNECT_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true, completion_expiry_stale_watchdog_races: 20,
  teardown_expiry_races: 20, completed_first_attempts_preserved: 40,
  actor_identity_immutability_checks: 1, unique_pending_attempt_checks: 1,
  provider_operations: 0,
  scope: "Repeated reconnect outcome arbitration; transport is not exercised by this database proof"
}))
