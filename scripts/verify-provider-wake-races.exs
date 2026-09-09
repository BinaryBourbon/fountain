alias Fountain.{Conversations, Quotas, Repo}
alias Fountain.Conversations.{LegacyResume, PromptDelivery, Sandbox, SandboxOperation, SandboxOperations, SandboxTransitions, WakeContext}
import Ecto.Query
config = Repo.config()
url = URI.parse(config[:url] || "")
host = config[:hostname] || url.host
database = config[:database] || String.trim_leading(url.path || "", "/")

if Mix.env() != :test or host not in ["localhost", "127.0.0.1"] or
     not String.starts_with?(database, "fountain_deadline_races_"),
   do: raise("This proof requires a dedicated local fountain_deadline_races_* database")

Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

defmodule ProviderWakeRace do
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

Application.put_env(:fountain, :sandboxes, fleet_ceiling: 100, cap_ceiling: 100)
fixture = fn managed ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "wake-race-#{Ecto.UUID.generate()}@example.test", comped: true})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-wake-#{Ecto.UUID.generate()}", status: "suspended"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
  sandbox = if managed do
    {:ok, pending} = Conversations.update_sandbox(sandbox, %{status: "pending"})
    {:ok, creation} = SandboxOperations._unsafe_submit_create(pending, parent)
    handle = %{Managoat.Sandbox.build_handle(:sprites, pending.sprite_name) | instance_id: Ecto.UUID.generate()}
    {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})
    {:ok, ready} = SandboxOperations._unsafe_finish_provision(pending, parent)
    {:ok, parked} = Conversations.update_sandbox(ready, %{status: "suspended"})
    parked
  else
    sandbox
  end
  {:ok, context} = WakeContext.new(parent, nil)
  %{sandbox: sandbox, parent: parent, context: context}
end
submit = fn c, managed ->
  if managed, do: SandboxTransitions._unsafe_submit(c.sandbox, "resume", c.context),
    else: LegacyResume.submit(c.context, c.sandbox)
end
for managed <- [false, true], _ <- 1..20 do
  c = fixture.(managed)
  results = ProviderWakeRace.concurrently([fn -> submit.(c, managed) end, fn -> submit.(c, managed) end])
  1 = Enum.count(results, &match?({:ok, _}, &1))
  1 = Enum.count(results, &match?({:error, _}, &1))
  1 = Repo.aggregate(from(o in SandboxOperation, where: o.sandbox_id == ^c.sandbox.id and o.action == "resume"), :count)
end
owner = self()
for managed <- [false, true] do
  c = fixture.(managed)
  Application.put_env(:fountain, :prompt_delivery_timeout_ms, 1_000)
  {:ok, receipt} = PromptDelivery.submit(c.parent.user_id, c.parent.id, "Local expired wake proof", [])
  {:ok, context} = WakeContext.new(c.parent, receipt.id)
  c = %{c | context: context}
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(c.sandbox.id)])
      send(owner, {:held, self()})
      receive do :release -> :ok after 10_000 -> raise "Lock release timed out" end
    end)
  end)
  receive do {:held, pid} when pid == holder.pid -> :ok after 5_000 -> raise "No holder" end
  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:backend, self(), backend})
      submit.(c, managed)
    end)
  end)
  backend = receive do {:backend, pid, backend} when pid == waiter.pid -> backend after 5_000 -> raise "No waiter" end
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  Process.sleep(max(DateTime.diff(context.deadline_at, DateTime.utc_now(), :millisecond), 0) + 20)
  send(holder.pid, :release)
  {:ok, :ok} = Task.await(holder)
  {:error, :wake_expired} = Task.await(waiter)
  0 = Repo.aggregate(from(o in SandboxOperation, where: o.sandbox_id == ^c.sandbox.id and o.action == "resume"), :count)
  true = Repo.reload!(receipt).delivery_deadline_at == context.deadline_at
end
# Kill the caller after its durable resume grant. The independent provider-task
# timer must still stop a blocked transport; no result authorizes releasing capacity.
c = fixture.(false)
context = %{c.context | deadline_at: DateTime.add(DateTime.utc_now(), 500, :millisecond)}
{:ok, operation} = LegacyResume.submit(context, c.sandbox)
caller = spawn(fn ->
  WakeContext.run(context, fn ->
    send(owner, {:transport, self()})
    receive do :never -> :ok end
  end)
end)
provider = receive do {:transport, pid} -> pid after 2_000 -> raise "Provider task did not start" end
ref = Process.monitor(provider)
caller_ref = Process.monitor(caller)
Process.exit(caller, :kill)
receive do {:DOWN, ^caller_ref, :process, ^caller, :killed} -> :ok after 2_000 -> raise "Caller survived" end
receive do {:DOWN, ^ref, :process, ^provider, :killed} -> :ok after 2_000 -> raise "Orphan provider task survived" end
"submitted" = Repo.reload!(operation).state
{:ok, _} = SandboxOperations._unsafe_mark_uncertain(operation.id)
true = Repo.reload!(operation).holds_slot
{:error, :provider_operation_fenced} = LegacyResume.submit(c.context, Repo.reload!(c.sandbox))
# Database protection applies even when callers bypass the Ecto changeset.
{:error, %Postgrex.Error{}} = Repo.query("UPDATE sandbox_operations SET wake_deadline_at = wake_deadline_at + interval '1 second' WHERE id = $1", [Ecto.UUID.dump!(operation.id)])
true = Repo.reload!(operation).wake_deadline_at == context.deadline_at
bad_id = Ecto.UUID.dump!(Ecto.UUID.generate())
{:error, %Postgrex.Error{}} = Repo.query("INSERT INTO sandbox_operations (id, sandbox_id, user_id, conversation_id, provider, sandbox_name, action, state, submitted_at, wake_deadline_at, wake_request_id, inserted_at, updated_at) SELECT $1, sandbox_id, user_id, conversation_id, provider, sandbox_name, 'resume', 'refused', submitted_at, wake_deadline_at, $1, now(), now() FROM sandbox_operations WHERE id = $2", [bad_id, Ecto.UUID.dump!(operation.id)])
IO.puts("PROVIDER_WAKE_RACE_RESULT=" <> Jason.encode!(%{
  duplicate_resume_races: 40, independent_connections_per_race: 2,
  expired_grants_refused_after_database_lock_wait: 2,
  orphan_provider_task_stopped: true, uncertain_resume_capacity_retained: true,
  immutable_deadline_enforced_by_sql: true, missing_receipt_rejected_by_sql: true,
  provider_operations: 0, fleet_count: Quotas.fleet_count(),
  scope: "Local PostgreSQL and blocked transport simulation; no live-provider recovery or legacy cleanup race proof"
}))
