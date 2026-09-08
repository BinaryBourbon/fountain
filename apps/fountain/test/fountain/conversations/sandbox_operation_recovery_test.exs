defmodule Fountain.Conversations.SandboxOperationRecoveryTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Quotas
  alias Fountain.Conversations.{SandboxOperation, SandboxOperations}
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "pending", mode: "ephemeral")
    parent = insert_conversation(user_id: user.id, sandbox: sandbox)
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, parent)
    %{user: user, sandbox: sandbox, parent: parent, creation: creation}
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -60, :second)

  defp confirm(c) do
    handle = %Handle{provider: :sprites, name: c.sandbox.sprite_name, instance_id: "instance"}
    {:ok, _} = SandboxOperations._unsafe_complete_create(c.creation.id, {:ok, handle})
    Repo.reload!(c.creation)
  end

  defp uncertain_delete(c) do
    confirm(c)
    {:ok, deletion} = SandboxOperations._unsafe_submit_destroy(c.sandbox)
    {:ok, _} = SandboxOperations._unsafe_mark_uncertain(deletion.id)
    deletion
  end

  test "stale create submission becomes uncertain without a probe or released slot", c do
    old = DateTime.add(DateTime.utc_now(), -200, :second)

    Repo.update_all(from(o in SandboxOperation, where: o.id == ^c.creation.id),
      set: [submitted_at: old]
    )

    assert SandboxOperations._unsafe_recover_submissions(cutoff()) == 1
    assert Repo.reload!(c.creation).state == "uncertain"

    assert SandboxOperations._unsafe_recovery_candidates(cutoff()) == %{
             cleanup: [],
             reconcile: []
           }

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_reconcile_destroy(c.creation.id, cutoff(), fn _ ->
               flunk("a missing name cannot settle a still-pending create")
             end)

    assert Repo.reload!(c.creation).holds_slot
    assert Quotas.fleet_count() == 1
    assert SandboxOperations._unsafe_recover_submissions(cutoff()) == 0
  end

  test "live holders and parked homes are not cleanup candidates", c do
    confirm(c)
    assert SandboxOperations._unsafe_recovery_candidates(cutoff()).cleanup == []

    assert {:error, :sandbox_held} =
             SandboxOperations._unsafe_recover_creation(c.creation.id, cutoff())

    assert Repo.reload!(c.creation).recovery_checked_at

    Repo.delete!(c.parent)
    c.sandbox |> Ecto.Changeset.change(mode: "persistent", status: "suspended") |> Repo.update!()
    assert SandboxOperations._unsafe_recovery_candidates(DateTime.utc_now()).cleanup == []
  end

  test "a retired final ephemeral holder allows one cleanup outside database locks", c do
    creation = confirm(c)
    Repo.delete!(c.parent)
    assert SandboxOperations._unsafe_recovery_candidates(cutoff()).cleanup == [creation.id]

    expect(Managoat.Sandbox.Sprites, :destroy_once, fn handle, _ ->
      refute Repo.in_transaction?()
      assert handle.instance_id == creation.provider_instance_id
      assert Repo.reload!(c.sandbox).status == "terminated"
      assert Quotas.fleet_count() == 1
      :ok
    end)

    assert :ok = SandboxOperations._unsafe_recover_creation(creation.id, cutoff())
    assert Quotas.fleet_count() == 0

    assert {:error, :recovery_throttled} =
             SandboxOperations._unsafe_recover_creation(creation.id, cutoff())
  end

  test "an added holder is rechecked after the candidate scan", c do
    creation = confirm(c)
    Repo.delete!(c.parent)
    assert SandboxOperations._unsafe_recovery_candidates(cutoff()).cleanup == [creation.id]
    insert_conversation(user_id: c.user.id, sandbox: c.sandbox)
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    assert {:error, :sandbox_held} =
             SandboxOperations._unsafe_recover_creation(creation.id, cutoff())

    assert Repo.reload!(c.sandbox).status == "pending"
  end

  test "confirmed creation retains cleanup after account deletion nilifies the sandbox owner",
       c do
    creation = confirm(c)
    Repo.delete!(c.user)
    assert Repo.reload!(c.sandbox).user_id == nil
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> :ok end)

    assert :ok = SandboxOperations._unsafe_recover_creation(creation.id, cutoff())
    assert %{status: "terminated", terminated_at: %DateTime{}} = Repo.reload!(c.sandbox)
    refute Repo.reload!(creation).holds_slot
    assert Quotas.fleet_count() == 0
  end

  test "confirmed creation can be cleaned after both parent rows disappear", c do
    creation = confirm(c)
    Repo.delete!(c.parent)
    Repo.delete!(c.sandbox)
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> :ok end)
    assert :ok = SandboxOperations._unsafe_recover_creation(creation.id, cutoff())
    refute Repo.reload!(creation).holds_slot
  end

  test "absence reconciles an uncertain delete without another provider write", c do
    deletion = uncertain_delete(c)
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    assert :ok =
             SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff(), fn handle ->
               refute Repo.in_transaction?()
               assert handle.name == c.sandbox.sprite_name
               assert handle.instance_id == "instance"
               {:error, :not_found}
             end)

    assert Repo.reload!(deletion).state == "confirmed"
    assert Quotas.fleet_count() == 0
  end

  test "presence and ambiguous results retain capacity and throttle another observer", c do
    deletion = uncertain_delete(c)

    assert {:error, :provider_operation_uncertain} =
             SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff(), fn _ ->
               {:ok, %{}}
             end)

    assert {:error, :recovery_throttled} =
             SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff(), fn _ ->
               flunk("duplicate probe")
             end)

    assert Repo.reload!(deletion).state == "uncertain"
    assert Quotas.fleet_count() == 1
  end

  test "ownership drift during observation cannot release the reservation", c do
    deletion = uncertain_delete(c)
    foreign = insert_verified_user()

    assert {:error, :ownership_changed} =
             SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff(), fn _ ->
               c.sandbox |> Ecto.Changeset.change(user_id: foreign.id) |> Repo.update!()
               {:error, :not_found}
             end)

    assert Repo.reload!(c.creation).holds_slot
    assert Repo.reload!(deletion).state == "uncertain"
  end

  test "a nilified owner does not authorize cleanup while that account still exists", c do
    confirm(c)
    c.sandbox |> Ecto.Changeset.change(user_id: nil, status: "failed") |> Repo.update!()
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    assert {:error, :ownership_changed} =
             SandboxOperations._unsafe_recover_creation(c.creation.id, cutoff())

    assert Repo.reload!(c.creation).holds_slot
  end

  test "provider identity drift refuses a recovery probe", c do
    deletion = uncertain_delete(c)
    c.sandbox |> Ecto.Changeset.change(provider_instance_id: "successor") |> Repo.update!()

    assert {:error, :ownership_changed} =
             SandboxOperations._unsafe_reconcile_destroy(deletion.id, cutoff(), fn _ ->
               flunk("wrong incarnation")
             end)

    assert Repo.reload!(c.creation).holds_slot
  end

  test "a refused candidate cannot monopolize a bounded recovery batch", c do
    confirm(c)
    Repo.delete!(c.parent)

    sandbox = insert_sandbox(user_id: c.user.id, status: "pending", mode: "ephemeral")
    parent = insert_conversation(user_id: c.user.id, sandbox: sandbox)
    {:ok, other} = SandboxOperations._unsafe_submit_create(sandbox, parent)
    handle = %Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: "other-instance"}
    {:ok, _} = SandboxOperations._unsafe_complete_create(other.id, {:ok, handle})
    Repo.delete!(parent)

    assert %{cleanup: [first]} = SandboxOperations._unsafe_recovery_candidates(cutoff(), 1)
    bad = if first == c.creation.id, do: c.sandbox, else: sandbox
    foreign = insert_verified_user()
    bad |> Ecto.Changeset.change(user_id: foreign.id) |> Repo.update!()

    assert {:error, :ownership_changed} =
             SandboxOperations._unsafe_recover_creation(first, cutoff())

    assert %{cleanup: [next]} = SandboxOperations._unsafe_recovery_candidates(cutoff(), 1)
    assert next != first
    assert Enum.sort([first, next]) == Enum.sort([c.creation.id, other.id])
  end
end
