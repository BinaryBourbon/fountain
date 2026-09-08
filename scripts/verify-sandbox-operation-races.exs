# Reuse the checked-in independent-connection barrier and local/test database guard.
# Its deadline races also verify the predecessor journal's arbitration.
Code.require_file("scripts/verify-turn-deadline-races.exs")

alias Fountain.Repo
alias Fountain.Conversations.{Conversation, Sandbox, SandboxOperation, SandboxOperations}
alias Managoat.Sandbox.Handle
import Ecto.Query

{:ok, _} = Application.ensure_all_started(:mimic)
:ok = Mimic.copy(Managoat.Sandbox)
:ok = Mimic.set_mimic_global()
deletes = :atomics.new(1, [])
probes = :atomics.new(1, [])

Mimic.stub(Managoat.Sandbox, :destroy_once, fn _ ->
  false = Repo.in_transaction?()
  :atomics.add(deletes, 1, 1)
  :ok
end)

fixture = fn confirmed? ->
  user =
    Repo.insert!(%Fountain.Accounts.User{email: "recovery-#{Ecto.UUID.generate()}@example.test"})

  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-recovery-#{Ecto.UUID.generate()}",
      mode: "ephemeral",
      status: "pending"
    })

  parent =
    Repo.insert!(%Conversation{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "idle"
    })

  {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, parent)

  handle = %Handle{
    provider: :sprites,
    name: sandbox.sprite_name,
    instance_id: Ecto.UUID.generate()
  }

  if confirmed?,
    do: {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})

  %{sandbox: sandbox, parent: parent, creation: creation, handle: handle}
end

cutoff = fn -> DateTime.add(DateTime.utc_now(), -60, :second) end

for _ <- 1..20 do
  c = fixture.(true)
  Repo.delete!(c.parent)
  before = :atomics.get(deletes, 1)

  results =
    DeadlineRace.concurrently([
      fn -> SandboxOperations._unsafe_recover_creation(c.creation.id, cutoff.()) end,
      fn -> SandboxOperations._unsafe_recover_creation(c.creation.id, cutoff.()) end
    ])

  1 = Enum.count(results, &(&1 == :ok))
  1 = Enum.count(results, &(&1 == {:error, :recovery_throttled}))
  true = :atomics.get(deletes, 1) == before + 1
  false = Repo.reload!(c.creation).holds_slot
end

for _ <- 1..20 do
  c = fixture.(false)
  old = DateTime.add(DateTime.utc_now(), -200, :second)

  Repo.update_all(from(o in SandboxOperation, where: o.id == ^c.creation.id),
    set: [submitted_at: old]
  )

  [_, {:ok, _}] =
    DeadlineRace.concurrently([
      fn -> SandboxOperations._unsafe_recover_submissions(cutoff.()) end,
      fn -> SandboxOperations._unsafe_complete_create(c.creation.id, {:ok, c.handle}) end
    ])

  %{state: "confirmed", holds_slot: true} = Repo.reload!(c.creation)
end

for _ <- 1..20 do
  c = fixture.(true)
  {:ok, deletion} = SandboxOperations._unsafe_submit_destroy(c.sandbox)
  {:ok, _} = SandboxOperations._unsafe_mark_uncertain(deletion.id)
  before = :atomics.get(probes, 1)

  probe = fn _ ->
    false = Repo.in_transaction?()
    :atomics.add(probes, 1, 1)
    {:error, :not_found}
  end

  results =
    DeadlineRace.concurrently([
      fn -> SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff.(), probe) end,
      fn -> SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff.(), probe) end
    ])

  1 = Enum.count(results, &(&1 == :ok))

  1 =
    Enum.count(
      results,
      &(&1 in [{:error, :recovery_throttled}, {:error, :provider_operation_fenced}])
    )

  true = :atomics.get(probes, 1) == before + 1
  false = Repo.reload!(c.creation).holds_slot
end

IO.puts(
  "SANDBOX_OPERATION_RACE_RESULT=" <>
    Jason.encode!(%{
      cleanup_claim_races: 20,
      stale_submission_late_reply_races: 20,
      observation_claim_races: 20,
      synthetic_deletes: :atomics.get(deletes, 1),
      synthetic_probes: :atomics.get(probes, 1),
      separate_database_connections: true,
      live_provider_operations: 0
    })
)
