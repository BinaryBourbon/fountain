# This inherited proof enforces a dedicated local test database and provides
# barriers that verify separate PostgreSQL backend connections.
Code.require_file("scripts/verify-actor-launch-races.exs")
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ActorClaim, ActorLaunch, ActorLaunches, ActorOwnership,
  PromptDelivery, PromptReceipt, Sandbox}
import Ecto.Query

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "reconnect-#{Ecto.UUID.generate()}@example.test", comped: true})
  agent = Repo.insert!(%Fountain.Agents.Agent{user_id: user.id, name: "Local reconnect proof", runtime: "claude", model: "anthropic/opus"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, agent_id: agent.id, sprite_name: "local-reconnect-#{Ecto.UUID.generate()}", status: "ready"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, agent_id: agent.id, sandbox_id: sandbox.id, runtime: agent.runtime, status: "idle"})
  %{user: user, sandbox: sandbox, parent: parent}
end
claim = fn c, launch ->
  ActorOwnership.start(%{actor_claim: Ecto.UUID.generate(), launch_id: launch.id}, c.parent, c.sandbox, 30_000)
end

launches = for _ <- 1..20 do
  c = fixture.()
  [{:ok, {_, first}}, {:ok, {_, second}}] = LaunchRace.concurrently([
    fn -> ActorLaunches.reconnect(c.parent, c.sandbox) end,
    fn -> ActorLaunches.reconnect(c.parent, c.sandbox) end
  ])
  true = first.id == second.id
  1 = Repo.aggregate(from(l in ActorLaunch, where: l.conversation_id == ^c.parent.id), :count)
  1 = Repo.aggregate(from(j in Oban.Job, where: j.worker == "Fountain.Workers.ActorLaunchDispatch" and fragment("?->>'launch_id'", j.args) == ^first.id), :count)
  results = LaunchRace.concurrently([fn -> claim.(c, first) end, fn -> claim.(c, first) end])
  [{:ok, state, _, _}] = Enum.filter(results, &match?({:ok, _, _, _}, &1))
  [{:error, :actor_owned}] = Enum.filter(results, &match?({:error, _}, &1))
  true = Repo.reload!(first).actor_claim_id == state.actor_claim
  true = Repo.get!(ActorClaim, state.actor_claim).launch_id == first.id
  "ready" = Repo.reload!(c.sandbox).status
  first
end

for _ <- 1..20 do
  c = fixture.()
  {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
  [claimed, refused] = LaunchRace.concurrently([
    fn -> claim.(c, launch) end,
    fn -> ActorLaunches.refuse(launch, "start_failed") end
  ])
  case Repo.reload!(launch).state do
    "acknowledged" ->
      {:ok, _, _, _} = claimed
      {:error, :launch_settled} = refused
    "refused" ->
      {:error, :launch_unavailable} = claimed
      {:ok, _} = refused
  end
  "ready" = Repo.reload!(c.sandbox).status
  "idle" = Repo.reload!(c.parent).status
end

for boundary <- [:identity, :receipt_deadline] do
  c = fixture.()
  receipt = if boundary == :receipt_deadline do
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.parent.id, "Local reconnect proof; no provider execution", [])
    receipt |> Ecto.Changeset.change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), 1, :second)) |> Repo.update!()
  end
  owner = self()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      case boundary do
        :identity ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(c.sandbox.id)])
          c.sandbox |> Ecto.Changeset.change(provider_instance_id: "changed-reconnect-#{Ecto.UUID.generate()}") |> Repo.update!()
        :receipt_deadline ->
          Repo.one!(from r in PromptReceipt, where: r.id == ^receipt.id, lock: "FOR UPDATE")
      end
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:holder, self(), backend})
      receive do
        :commit -> :ok
      after
        5_000 -> raise "Reconnect holder barrier timed out"
      end
    end)
  end)
  holder_backend = receive do
    {:holder, pid, backend} when pid == holder.pid -> backend
  after
    5_000 -> raise "Reconnect holder checkout timed out"
  end
  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:waiter, self(), backend})
      ActorLaunches.reconnect(c.parent, c.sandbox, receipt && receipt.id)
    end)
  end)
  waiter_backend = receive do
    {:waiter, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "Reconnect waiter checkout timed out"
  end
  true = holder_backend != waiter_backend
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  if receipt, do: Process.sleep(max(DateTime.diff(receipt.delivery_deadline_at, DateTime.utc_now(), :millisecond), 0) + 5)
  send(holder.pid, :commit)
  {:ok, :ok} = Task.await(holder, 10_000)
  expected = if boundary == :identity, do: :ownership_changed, else: :delivery_expired
  {:error, ^expected} = Task.await(waiter, 10_000)
  "ready" = Repo.reload!(c.sandbox).status
  0 = Repo.aggregate(from(l in ActorLaunch, where: l.conversation_id == ^c.parent.id), :count)
end

launch = hd(launches)
try do
  Repo.transaction(fn ->
    Repo.query!("UPDATE actor_launches SET reconnect_identity = '{}'::jsonb WHERE id = $1", [Ecto.UUID.dump!(launch.id)])
  end)
  raise "Reconnect physical identity was rewritten"
rescue
  error in Postgrex.Error -> :raise_exception = error.postgres.code
end

c = fixture.()
{:ok, {_, pending}} = ActorLaunches.reconnect(c.parent, c.sandbox)
try do
  Repo.transaction(fn ->
    Repo.query!("INSERT INTO actor_launches (id, user_id, conversation_id, sandbox_id, runtime, kind, reconnect_identity, deadline_at, state, inserted_at, updated_at) SELECT $1, user_id, conversation_id, sandbox_id, runtime, kind, reconnect_identity, deadline_at, state, inserted_at, updated_at FROM actor_launches WHERE id = $2", [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(pending.id)])
  end)
  raise "Duplicate pending reconnect was admitted"
rescue
  error in Postgrex.Error ->
    :unique_violation = error.postgres.code
    "actor_launches_pending_parent_index" = error.postgres.constraint
end

IO.puts("READY_WAKE_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true, concurrent_reconnects: 20, duplicate_claims: 20,
  claim_refusal_races: 20, forced_identity_waits: 1, forced_receipt_deadline_waits: 1,
  sql_identity_immutability: 1, sql_pending_request_uniqueness: 1, provider_operations: 0,
  scope: "Ready-machine startup handoff; suspended provider wake, abandoned actors and live recovery remain unproven"
}))
