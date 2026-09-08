# Reuse the prior verifier's isolated-database guard and independent connection
# barriers. Its fixture history remains intact during this additional proof.
Code.require_file("scripts/verify-actor-startup-races.exs")
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ActorClaim, ActorOwnership, ActorStartup, ExecutionDeadlineWorker, LogEvent, Sandbox}
import Ecto.Query

await = fn predicate ->
  true = Enum.reduce_while(1..1_000, false, fn _, _ ->
    if predicate.(), do: {:halt, true}, else: (Process.sleep(10); {:cont, false})
  end)
end
user = Repo.insert!(%Fountain.Accounts.User{email: "startup-recovery-#{Ecto.UUID.generate()}@example.test", comped: true})
machine = fn -> Repo.insert!(%Sandbox{user_id: user.id,
  sprite_name: "recovery-#{Ecto.UUID.generate()}", status: "ready"}) end
blocked_machines = for _ <- 1..8, do: machine.()
fixture = fn sandbox, prefix ->
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id,
    sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
  id = prefix <> String.slice(Ecto.UUID.generate(), 8..-1//1)
  {:ok, claim} = ActorOwnership.claim(user.id, parent.id, sandbox.id, id)
  startup = Repo.insert!(%ActorStartup{id: id, actor_claim_id: id, user_id: user.id,
    conversation_id: parent.id, sandbox_id: sandbox.id,
    deadline_at: DateTime.add(DateTime.utc_now(), -1)})
  %{startup: startup, claim: claim, parent: parent}
end
blocked = for sandbox <- blocked_machines, do: fixture.(sandbox, "00000000")
waiting = fixture.(machine.(), "ffffffff")
blocked_ids = MapSet.new(blocked, & &1.startup.id)
owner = self()
holder = Task.async(fn ->
  Repo.transaction(fn ->
    Enum.each(blocked_machines, fn sandbox ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox.id)])
    end)
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    send(owner, {:lock_held, backend})
    receive do
      :release -> :ok
    after
      20_000 -> raise "Recovery proof lock timed out"
    end
  end)
end)
receive do {:lock_held, _backend} -> :ok after 5_000 -> raise "Lock not acquired" end
opts = [interval_ms: 20, job_timeout_ms: 500, terminator: fn _ ->
  send(owner, :unexpected_provider_operation)
  {:error, :local_proof_forbids_provider_calls}
end]
{:ok, coordinator} = GenServer.start(ExecutionDeadlineWorker, opts)
await.(fn ->
  jobs = :sys.get_state(coordinator).jobs
  Enum.count(jobs, fn {_, job} -> job.kind == :startup_expiry and MapSet.member?(blocked_ids, job.id) end) == 8
end)
# The blocked operations use eight independent database connections, not SQL
# Sandbox's shared test connection. Every one waits on the held machine locks.
await.(fn ->
  %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%pg_advisory_xact_lock%'")
  count >= 8
end)
await.(fn -> Repo.reload!(waiting.startup).state == "expired" end)
true = Enum.all?(blocked, &(Repo.reload!(&1.startup).state == "starting"))
# Wait for the next attempt at the blocked rows, then kill their coordinator.
# Each task's own timer must still stop it; no scan result releases ownership.
await.(fn ->
  jobs = :sys.get_state(coordinator).jobs
  Enum.count(jobs, fn {_, job} -> job.kind == :startup_expiry and MapSet.member?(blocked_ids, job.id) end) == 8
end)
tasks = for {_, %{kind: :startup_expiry, task: task}} <- :sys.get_state(coordinator).jobs, do: task.pid
8 = length(tasks)
monitors = for pid <- tasks, do: {pid, Process.monitor(pid)}
coordinator_monitor = Process.monitor(coordinator)
Process.exit(coordinator, :kill)
receive do {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed} -> :ok after 2_000 -> raise "Coordinator survived kill" end
for {pid, ref} <- monitors do
  receive do {:DOWN, ^ref, :process, ^pid, :killed} -> :ok after 2_000 -> raise "Orphan expiry task survived its timeout" end
end
true = Enum.all?(blocked, &(Repo.reload!(&1.startup).state == "starting"))
send(holder.pid, :release)
{:ok, :ok} = Task.await(holder, 5_000)
{:ok, restarted} = GenServer.start(ExecutionDeadlineWorker, opts)
await.(fn -> Enum.all?(blocked, &(Repo.reload!(&1.startup).state == "expired")) end)
GenServer.stop(restarted)
for c <- [waiting | blocked] do
  true = Repo.reload!(c.startup).deadline_at == c.startup.deadline_at
  "active" = Repo.get!(ActorClaim, c.claim.id).state
  1 = Repo.aggregate(from(e in LogEvent, where: e.conversation_id == ^c.parent.id), :count)
end
true = Enum.all?(blocked_machines, &(Repo.reload!(&1).status == "ready"))
receive do :unexpected_provider_operation -> raise "Startup recovery attempted provider work" after 0 -> :ok end
IO.puts("STARTUP_RECOVERY_RACE_RESULT=" <> Jason.encode!(%{
  independent_blocked_database_connections: 8,
  later_attempt_expired_while_first_eight_locked: true,
  orphan_tasks_stopped_after_coordinator_loss: 8,
  persisted_expiry_after_restart: 8,
  original_deadlines_and_active_claims_retained: 9,
  unique_failure_events: 9,
  provider_operations: 0,
  scope: "Local coordinator contention, crash and restart over PostgreSQL; not distributed-node or live-provider recovery"
}))
