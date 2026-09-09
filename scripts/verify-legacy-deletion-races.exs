alias Fountain.{Conversations, Quotas, Repo}

alias Fountain.Conversations.{
  LegacyDeletion,
  LegacyResume,
  Sandbox,
  SandboxOperation,
  SandboxOperations,
  WakeContext
}

import Ecto.Query
config = Repo.config()
url = URI.parse(config[:url] || "")
host = config[:hostname] || url.host
database = config[:database] || String.trim_leading(url.path || "", "/")

if Mix.env() != :test or host not in ["localhost", "127.0.0.1"] or
     not String.starts_with?(database, "fountain_deadline_races_"),
   do: raise("This proof requires a dedicated local fountain_deadline_races_* database")

Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

defmodule LegacyDeletionRace do
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

# No adapter capable of network I/O is registered in this proof VM.
defmodule LegacyDeletionProofAdapter do
  def capabilities, do: MapSet.new([:destroy_once])
  def build_handle(name), do: %Managoat.Sandbox.Handle{provider: :sprites, name: name}

  def destroy_once(handle, _opts) do
    false = Fountain.Repo.in_transaction?()

    send(
      Application.fetch_env!(:fountain, :legacy_deletion_proof_owner),
      {:provider_entered, self(), handle.name}
    )

    receive do
      :finish -> :ok
    after
      10_000 -> raise "Fake provider barrier timed out"
    end
  end
end

Application.put_env(:managoat_sandbox, :adapters, %{sprites: LegacyDeletionProofAdapter})
Application.put_env(:fountain, :sandboxes, fleet_ceiling: 100, cap_ceiling: 100)
Application.put_env(:fountain, :legacy_deletion_proof_owner, self())

fixture = fn ->
  user =
    Repo.insert!(%Fountain.Accounts.User{
      email: "legacy-delete-#{Ecto.UUID.generate()}@example.test",
      comped: true
    })

  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-delete-#{Ecto.UUID.generate()}",
      status: "suspended"
    })

  {:ok, parent} =
    Conversations.create_conversation(%{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "idle"
    })

  {:ok, context} = WakeContext.new(parent, nil)

  %{
    sandbox: sandbox,
    parent: parent,
    context: context,
    handle: Managoat.Sandbox.build_handle(:sprites, sandbox.sprite_name)
  }
end

for _ <- 1..20 do
  c = fixture.()

  results =
    LegacyDeletionRace.concurrently([
      fn -> LegacyDeletion.submit(c.sandbox, c.handle) end,
      fn -> LegacyResume.submit(c.context, c.sandbox) end
    ])

  1 = Enum.count(results, &match?({:ok, _}, &1))
  1 = Enum.count(results, &match?({:error, :ownership_changed}, &1))
  1 = Repo.aggregate(from(o in SandboxOperation, where: o.sandbox_id == ^c.sandbox.id), :count)
end

for _ <- 1..20 do
  c = fixture.()

  results =
    LegacyDeletionRace.concurrently([
      fn -> LegacyDeletion.submit(c.sandbox, c.handle) end,
      fn -> LegacyDeletion.submit(c.sandbox, c.handle) end
    ])

  1 = Enum.count(results, &match?({:ok, _}, &1))
  1 = Enum.count(results, &match?({:error, :ownership_changed}, &1))
end

for _ <- 1..20 do
  c = fixture.()
  {:ok, operation} = LegacyDeletion.submit(c.sandbox, c.handle)

  results =
    LegacyDeletionRace.concurrently([
      fn -> LegacyDeletion.claim(operation.id) end,
      fn -> LegacyDeletion.claim(operation.id) end
    ])

  1 = Enum.count(results, &match?({:ok, _}, &1))
  1 = Enum.count(results, &match?({:error, :provider_operation_fenced}, &1))
  true = not is_nil(Repo.reload!(operation).delete_started_at)
end

owner = self()
c = fixture.()
{:ok, expired} = LegacyDeletion.submit(c.sandbox, c.handle, timeout_ms: 1_000)

holder =
  Task.async(fn ->
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(c.sandbox.id)])
      send(owner, {:held, self()})

      receive do
        :release -> :ok
      after
        10_000 -> raise "Lock release timed out"
      end
    end)
  end)

receive do
  {:held, pid} when pid == holder.pid -> :ok
after
  5_000 -> raise "No holder"
end

waiter =
  Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:backend, self(), backend})
      LegacyDeletion.claim(expired.id)
    end)
  end)

backend =
  receive do
    {:backend, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "No waiter"
  end

true =
  Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
      [["Lock"]] ->
        {:halt, true}

      _ ->
        Process.sleep(5)
        {:cont, false}
    end
  end)

Process.sleep(
  max(DateTime.diff(expired.delete_deadline_at, DateTime.utc_now(), :millisecond), 0) + 20
)

send(holder.pid, :release)
{:ok, :ok} = Task.await(holder)
{:error, :provider_operation_fenced} = Task.await(waiter)
"refused" = Repo.reload!(expired).state
nil = Repo.reload!(expired).delete_started_at
true = Repo.reload!(expired).holds_slot
# The original failing scenario now crosses the real dispatch path, using only
# this registered fake adapter. Resume is refused while deletion is in flight.
c = fixture.()
caller = Task.async(fn -> LegacyDeletion.destroy(c.sandbox, c.handle) end)

provider =
  receive do
    {:provider_entered, pid, name} when name == c.sandbox.sprite_name -> pid
  after
    5_000 -> raise "No fake delete"
  end

operation = Repo.one!(from o in SandboxOperation, where: o.sandbox_id == ^c.sandbox.id)
true = not is_nil(operation.delete_started_at)
true = operation.holds_slot
nil = Repo.reload!(c.sandbox).terminated_at
{:error, :ownership_changed} = LegacyResume.submit(c.context, c.sandbox)

0 =
  Repo.aggregate(
    from(o in SandboxOperation, where: o.sandbox_id == ^c.sandbox.id and o.action == "resume"),
    :count
  )

send(provider, :finish)
:ok = Task.await(caller)
false = Repo.reload!(operation).holds_slot
"confirmed" = Repo.reload!(operation).state
# Caller death cannot lose the provider task's hard timer or reopen dispatch.
c = fixture.()
{:ok, orphan} = LegacyDeletion.submit(c.sandbox, c.handle, timeout_ms: 500)
caller = spawn(fn -> LegacyDeletion.dispatch(orphan.id) end)

provider =
  receive do
    {:provider_entered, pid, name} when name == c.sandbox.sprite_name -> pid
  after
    2_000 -> raise "No orphan provider"
  end

provider_ref = Process.monitor(provider)
caller_ref = Process.monitor(caller)
Process.exit(caller, :kill)

receive do
  {:DOWN, ^caller_ref, :process, ^caller, :killed} -> :ok
after
  2_000 -> raise "Caller survived"
end

receive do
  {:DOWN, ^provider_ref, :process, ^provider, :killed} -> :ok
after
  2_000 -> raise "Provider survived deadline"
end

{:error, :provider_operation_fenced} = LegacyDeletion.dispatch(orphan.id)
{:ok, _} = SandboxOperations._unsafe_mark_uncertain(orphan.id)
true = Repo.reload!(orphan).holds_slot
started = Repo.reload!(orphan).delete_started_at

{:error, %Postgrex.Error{}} =
  Repo.query("UPDATE sandbox_operations SET delete_started_at = NULL WHERE id = $1", [
    Ecto.UUID.dump!(orphan.id)
  ])

true = Repo.reload!(orphan).delete_started_at == started

{:error, %Postgrex.Error{}} =
  Repo.query(
    "UPDATE sandbox_operations SET delete_deadline_at = delete_deadline_at + interval '1 second' WHERE id = $1",
    [Ecto.UUID.dump!(orphan.id)]
  )

true = Repo.reload!(orphan).delete_deadline_at == orphan.delete_deadline_at
# A retained legacy name must also exclude the ordinary fresh-create primitive.
c = fixture.()
{:ok, retained} = LegacyDeletion.submit(c.sandbox, c.handle)
Repo.delete!(c.sandbox)

replacement =
  Repo.insert!(%Sandbox{
    user_id: c.parent.user_id,
    sprite_name: c.sandbox.sprite_name,
    status: "pending"
  })

{:ok, parent} =
  Conversations.create_conversation(%{
    user_id: c.parent.user_id,
    sandbox_id: replacement.id,
    runtime: "claude",
    status: "pending"
  })

{:error, :provider_operation_fenced} =
  SandboxOperations._unsafe_submit_create(replacement, parent)

{:error, :ownership_changed} = LegacyDeletion.dispatch(retained.id)
true = Repo.reload!(retained).holds_slot

receive do
  {:provider_entered, _, _} -> raise "A duplicate dispatch reached the adapter"
after
  0 -> :ok
end

IO.puts(
  "LEGACY_DELETION_RACE_RESULT=" <>
    Jason.encode!(%{
      delete_resume_races: 20,
      duplicate_delete_races: 20,
      duplicate_dispatch_claim_races: 20,
      independent_connections_per_race: 2,
      expired_dispatch_refused_after_lock_wait: true,
      resume_refused_during_adapter_call: true,
      orphan_provider_task_stopped: true,
      duplicate_dispatch_refused_after_caller_loss: true,
      capacity_retained_on_uncertainty: true,
      immutable_deadline_and_dispatch_claim: true,
      retained_name_excludes_fresh_create: true,
      fake_adapter_calls: 2,
      live_provider_calls: 0,
      fleet_count: Quotas.fleet_count(),
      scope:
        "Local independent PostgreSQL connections and an in-memory adapter; no live-provider deletion or full legacy lifecycle integration proof"
    })
)
