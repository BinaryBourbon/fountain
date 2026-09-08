alias Fountain.Repo
alias Fountain.Conversations.{ActorClaim, ActorLaunch, ActorLaunches, ActorOwnership, Sandbox, PromptDelivery, PromptReceipt}
import Ecto.Query
config = Repo.config()
url = URI.parse(config[:url] || "")
host = config[:hostname] || url.host
database = config[:database] || String.trim_leading(url.path || "", "/")

if Mix.env() != :test or host not in ["localhost", "127.0.0.1"] or
     not String.starts_with?(database, "fountain_deadline_races_"),
   do: raise("This proof requires a dedicated local fountain_deadline_races_* database")

Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

defmodule LaunchRace do
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

fixture = fn timeout ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "launch-race-#{Ecto.UUID.generate()}@example.test", comped: true})
  agent = Repo.insert!(%Fountain.Agents.Agent{user_id: user.id, name: "Local launch proof", runtime: "claude", model: "anthropic/opus"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, agent_id: agent.id, sprite_name: "local-launch-#{Ecto.UUID.generate()}", status: "pending"})
  {:ok, parent} = Fountain.Conversations.create_conversation(%{user_id: user.id, agent_id: agent.id, sandbox_id: sandbox.id, runtime: "claude", status: "pending"})
  {:ok, receipt} = PromptDelivery.submit(user.id, parent.id, "Local launch proof; no provider execution", [])
  launch = Repo.insert!(%ActorLaunch{user_id: user.id, conversation_id: parent.id, sandbox_id: sandbox.id, runtime: parent.runtime, opening_receipt_id: receipt.id, deadline_at: DateTime.add(DateTime.utc_now(), timeout, :millisecond)})
  %{user: user, sandbox: sandbox, parent: parent, launch: launch, receipt: receipt}
end
claim = fn c ->
  ActorOwnership.start(%{actor_claim: Ecto.UUID.generate(), launch_id: c.launch.id}, c.parent, c.sandbox, 30_000)
end

for _ <- 1..20 do
  c = fixture.(60_000)
  results = LaunchRace.concurrently([fn -> claim.(c) end, fn -> claim.(c) end])
  [{:ok, state, _, _}] = Enum.filter(results, &match?({:ok, _, _, _}, &1))
  [{:error, :actor_owned}] = Enum.filter(results, &match?({:error, _}, &1))
  launch = Repo.reload!(c.launch)
  "acknowledged" = launch.state
  true = launch.actor_claim_id == state.actor_claim
  true = Repo.get!(ActorClaim, state.actor_claim).launch_id == launch.id
  1 = Repo.aggregate(from(a in ActorClaim, where: a.sandbox_id == ^c.sandbox.id), :count)
end

for _ <- 1..20 do
  c = fixture.(60_000)
  [claimed, refused] = LaunchRace.concurrently([
    fn -> claim.(c) end,
    fn -> ActorLaunches.refuse(c.launch, "start_failed") end
  ])
  case Repo.reload!(c.launch).state do
    "acknowledged" ->
      {:ok, _, _, _} = claimed
      {:error, :launch_settled} = refused
      "pending" = Repo.reload!(c.parent).status
      "queued" = Repo.reload!(c.receipt).state
      1 = Repo.aggregate(from(a in ActorClaim, where: a.sandbox_id == ^c.sandbox.id), :count)
    "refused" ->
      {:error, :ownership_changed} = claimed
      {:ok, _} = refused
      "failed" = Repo.reload!(c.parent).status
      "refused" = Repo.reload!(c.receipt).state
      0 = Repo.aggregate(from(a in ActorClaim, where: a.sandbox_id == ^c.sandbox.id), :count)
  end
end

# Hold the opening receipt until after the absolute deadline. The actor must
# take that row lock, then sample time; its earlier eligible read is insufficient.
c = fixture.(1_000)
owner = self()
holder = Task.async(fn ->
  Repo.transaction(fn ->
    Repo.one!(from r in PromptReceipt, where: r.id == ^c.receipt.id, lock: "FOR UPDATE")
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:holder, self(), backend})
    receive do
      :commit -> :ok
    after
      5_000 -> raise "Receipt barrier timed out"
    end
  end)
end)
holder_backend = receive do
  {:holder, pid, backend} when pid == holder.pid -> backend
 after
  5_000 -> raise "Receipt holder did not start"
end
waiter = Task.async(fn ->
  Repo.checkout(fn ->
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:waiter, self(), backend})
    claim.(c)
  end)
end)
waiter_backend = receive do
  {:waiter, pid, backend} when pid == waiter.pid -> backend
 after
  5_000 -> raise "Claim waiter did not start"
end
true = holder_backend != waiter_backend
true = Enum.reduce_while(1..200, false, fn _, _ ->
  case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
    [["Lock"]] -> {:halt, true}
    _ -> Process.sleep(5); {:cont, false}
  end
end)
Process.sleep(max(DateTime.diff(c.launch.deadline_at, DateTime.utc_now(), :millisecond), 0) + 5)
send(holder.pid, :commit)
{:ok, :ok} = Task.await(holder, 10_000)
{:error, :launch_expired} = Task.await(waiter, 10_000)
"requested" = Repo.reload!(c.launch).state
0 = Repo.aggregate(from(a in ActorClaim, where: a.sandbox_id == ^c.sandbox.id), :count)

# Raw SQL cannot move a launch or extend its accepted deadline.
for field <- ~w(id user_id conversation_id sandbox_id opening_receipt_id) do
  try do
    Repo.transaction(fn -> Repo.query!("UPDATE actor_launches SET #{field} = $1 WHERE id = $2", [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(c.launch.id)]) end)
    raise "Launch identity update was accepted"
  rescue
    error in Postgrex.Error -> :raise_exception = error.postgres.code
  end
end
try do
  Repo.transaction(fn -> Repo.query!("UPDATE actor_launches SET deadline_at = deadline_at + interval '1 hour' WHERE id = $1", [Ecto.UUID.dump!(c.launch.id)]) end)
  raise "Launch deadline was extended"
rescue
  error in Postgrex.Error -> :raise_exception = error.postgres.code
end

IO.puts("ACTOR_LAUNCH_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true, duplicate_claim_races: 20,
  claim_vs_refusal_races: 20, forced_opening_receipt_deadline_waits: 1,
  raw_sql_immutability_checks: 6, provider_operations: 0,
  scope: "Atomic launch/claim arbitration and deadline enforcement; not provider reconciliation or live recovery"
}))
