# The inherited proof refuses any database except a dedicated local test DB.
Code.require_file("scripts/verify-actor-launch-races.exs")
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ActorLaunch, ActorLaunches, PromptDelivery, PromptReceipt, Sandbox}
import Ecto.Query

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "fresh-wake-#{Ecto.UUID.generate()}@example.test", comped: true, sandbox_limit_override: 1})
  agent = Repo.insert!(%Fountain.Agents.Agent{user_id: user.id, name: "Local wake proof", runtime: "claude", model: "anthropic/opus"})
  source = Repo.insert!(%Sandbox{user_id: user.id, agent_id: agent.id, mode: "persistent", sprite_name: "local-wake-source-#{Ecto.UUID.generate()}", status: "ready"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, agent_id: agent.id, sandbox_id: source.id, runtime: agent.runtime, status: "idle"})
  %{user: user, source: Repo.reload!(source), parent: parent, agent: agent}
end
attrs = fn c ->
  %{user_id: c.user.id, agent_id: c.agent.id, mode: "persistent", sprite_name: "local-wake-target-#{Ecto.UUID.generate()}", status: "pending"}
end
cfg = Application.get_env(:fountain, :sandboxes, [])

launches = for _ <- 1..20 do
  c = fixture.()
  # Replacing the ready source leaves the fleet at exactly this ceiling. The
  # second caller must reuse the winner even when its quota precheck sees full.
  Application.put_env(:fountain, :sandboxes, Keyword.put(cfg, :fleet_ceiling, Fountain.Quotas.fleet_count()))
  [first, second] = LaunchRace.concurrently([
    fn -> ActorLaunches.replace(c.parent, c.source, attrs.(c)) end,
    fn -> ActorLaunches.replace(c.parent, c.source, attrs.(c)) end
  ])
  {:ok, {sandbox, parent, launch}} = first
  {:ok, {same, same_parent, same_launch}} = second
  true = same.id == sandbox.id and same_parent.id == parent.id and same_launch.id == launch.id
  true = Repo.reload!(c.parent).sandbox_id == sandbox.id
  true = launch.source_sandbox_id == c.source.id
  "terminated" = Repo.reload!(c.source).status
  "pending" = Repo.reload!(sandbox).status
  1 = Repo.aggregate(from(l in ActorLaunch, where: l.user_id == ^c.user.id), :count)
  2 = Repo.aggregate(from(s in Sandbox, where: s.user_id == ^c.user.id), :count)
  1 = Repo.aggregate(from(j in Oban.Job, where: j.worker == "Fountain.Workers.ActorLaunchDispatch" and fragment("?->>'launch_id'", j.args) == ^launch.id), :count)
  {:error, :fleet_full} = Fountain.Quotas.check_fleet_ceiling()
  {:error, {:sandbox_quota_exceeded, %{count: 1, limit: 1}}} = Fountain.Quotas.check_sandbox_quota(c.user.id)
  launch
end
Application.put_env(:fountain, :sandboxes, Keyword.put(cfg, :fleet_ceiling, Fountain.Quotas.fleet_count() + 20))

for boundary <- [:source_identity, :receipt_deadline] do
  c = fixture.()
  receipt = if boundary == :receipt_deadline do
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.parent.id, "Local wake proof; no provider calls", [])
    receipt |> Ecto.Changeset.change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), 1, :second)) |> Repo.update!()
  end
  owner = self()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      case boundary do
        :source_identity ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(c.source.id)])
          c.source |> Ecto.Changeset.change(provider_instance_id: "changed-local-incarnation-#{Ecto.UUID.generate()}") |> Repo.update!()
        :receipt_deadline ->
          Repo.one!(from r in PromptReceipt, where: r.id == ^receipt.id, lock: "FOR UPDATE")
      end
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:holder, self(), backend})
      receive do
        :commit -> :ok
      after
        5_000 -> raise "Wake holder barrier timed out"
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
      ActorLaunches.replace(c.parent, c.source, attrs.(c), receipt && receipt.id)
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
  if receipt, do: Process.sleep(max(DateTime.diff(receipt.delivery_deadline_at, DateTime.utc_now(), :millisecond), 0) + 5)
  send(holder.pid, :commit)
  {:ok, :ok} = Task.await(holder, 10_000)
  expected = if boundary == :source_identity, do: :ownership_changed, else: :delivery_expired
  {:error, ^expected} = Task.await(waiter, 10_000)
  true = Repo.reload!(c.parent).sandbox_id == c.source.id
  "ready" = Repo.reload!(c.source).status
  1 = Repo.aggregate(from(s in Sandbox, where: s.user_id == ^c.user.id), :count)
  0 = Repo.aggregate(from(l in ActorLaunch, where: l.user_id == ^c.user.id), :count)
end

launch = hd(launches)
try do
  Repo.transaction(fn ->
    Repo.query!("UPDATE actor_launches SET source_sandbox_id = $1 WHERE id = $2", [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(launch.id)])
  end)
  raise "Replacement source identity was rewritten"
rescue
  error in Postgrex.Error -> :raise_exception = error.postgres.code
end
try do
  Repo.transaction(fn ->
    Repo.query!("UPDATE actor_launches SET kind = 'create' WHERE id = $1", [Ecto.UUID.dump!(launch.id)])
  end)
  raise "Replacement purpose was rewritten"
rescue
  error in Postgrex.Error -> :raise_exception = error.postgres.code
end
Application.put_env(:fountain, :sandboxes, cfg)

IO.puts("FRESH_WAKE_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true, concurrent_replacements_at_account_and_fleet_cap: 20,
  forced_source_identity_waits: 1, forced_receipt_deadline_waits: 1,
  raw_sql_source_immutability_checks: 1, raw_sql_purpose_immutability_checks: 1, provider_operations: 0,
  scope: "Atomic fresh-wake replacement and launch; not abandoned-actor/provider reconciliation or live recovery"
}))
