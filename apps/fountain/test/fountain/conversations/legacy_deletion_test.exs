defmodule Fountain.Conversations.LegacyDeletionTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Quotas

  alias Fountain.Conversations.{
    LegacyDeletion,
    LegacyResume,
    SandboxOperation,
    SandboxOperations,
    WakeContext
  }

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "suspended")

    parent =
      insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "claude", status: "idle")

    {:ok, context} = WakeContext.new(parent, nil)
    handle = Managoat.Sandbox.build_handle(:sprites, sandbox.sprite_name)
    %{user: user, sandbox: sandbox, parent: parent, context: context, handle: handle}
  end

  test "provider deletion observes a committed grant, closed admission and retained capacity",
       c do
    expect(Managoat.Sandbox, :destroy_once, fn handle, _opts ->
      refute Repo.in_transaction?()
      assert handle.name == c.sandbox.sprite_name
      operation = Repo.one!(SandboxOperation)
      assert operation.action == "destroy"
      assert operation.state == "submitted"
      assert operation.holds_slot
      assert operation.user_id == c.user.id
      assert operation.delete_started_at
      assert operation.delete_deadline_at
      assert Repo.reload!(c.sandbox).status == "terminated"
      assert Repo.reload!(c.sandbox).terminated_at == nil
      assert Quotas.fleet_count() == 1
      assert {:error, :ownership_changed} = LegacyResume.submit(c.context, c.sandbox)
      assert [] = Repo.all(from o in SandboxOperation, where: o.action == "resume")
      :ok
    end)

    assert :ok = LegacyDeletion.destroy(c.sandbox, c.handle)
    assert Repo.one!(SandboxOperation).state == "confirmed"
    refute Repo.one!(SandboxOperation).holds_slot
    assert Quotas.fleet_count() == 0
    assert Repo.reload!(c.sandbox).terminated_at
    refute SandboxOperations._unsafe_managed?(c.sandbox.id)
  end

  test "a winning resume refuses deletion before any provider request", c do
    {:ok, operation} = LegacyResume.submit(c.context, c.sandbox)
    reject(Managoat.Sandbox, :destroy_once, 2)

    assert {:error, :provider_operation_fenced} =
             LegacyDeletion.destroy(Repo.reload!(c.sandbox), c.handle)

    assert Repo.reload!(c.sandbox).status == "suspended"
    assert Repo.reload!(operation).holds_slot
    assert Repo.aggregate(SandboxOperation, :count) == 1
  end

  test "uncertainty retains capacity and never replays deletion", c do
    expect(Managoat.Sandbox, :destroy_once, fn _, _ ->
      {:error, {:unavailable, :delete_unconfirmed}}
    end)

    assert {:error, :provider_operation_uncertain} = LegacyDeletion.destroy(c.sandbox, c.handle)
    operation = Repo.one!(SandboxOperation)
    assert operation.state == "uncertain"
    assert operation.holds_slot
    assert Repo.reload!(c.sandbox).terminated_at == nil
    assert Quotas.fleet_count() == 1
    reject(Managoat.Sandbox, :destroy_once, 2)

    assert {:error, :provider_operation_fenced} =
             LegacyDeletion.destroy(Repo.reload!(c.sandbox), c.handle)

    assert Repo.aggregate(SandboxOperation, :count) == 1
  end

  test "an adapter without bounded deletion cannot fall back to generic deletion", c do
    stub(Managoat.Sandbox, :supports?, fn _, :destroy_once -> false end)
    reject(Managoat.Sandbox, :destroy_once, 2)
    reject(Managoat.Sandbox, :destroy, 1)
    assert {:error, :not_supported} = LegacyDeletion.destroy(c.sandbox, c.handle)
    assert Repo.aggregate(SandboxOperation, :count) == 0
    assert Repo.reload!(c.sandbox).status == "suspended"
  end

  test "a cotenant holder and a foreign handle each refuse a grant", c do
    insert_conversation(user_id: c.user.id, sandbox: c.sandbox, runtime: "claude", status: "idle")
    reject(Managoat.Sandbox, :destroy_once, 2)

    assert {:error, :sandbox_held} =
             LegacyDeletion.destroy(c.sandbox, c.handle, holder: c.parent.id)

    assert {:error, :ownership_changed} =
             LegacyDeletion.destroy(c.sandbox, %{c.handle | name: "different-machine"})

    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  test "late success cannot release a different owner's machine reservation", c do
    {:ok, operation} = LegacyDeletion.submit(c.sandbox, c.handle)
    {:ok, _} = LegacyDeletion.claim(operation.id)

    Repo.reload!(c.sandbox)
    |> Ecto.Changeset.change(user_id: insert_verified_user().id)
    |> Repo.update!()

    assert {:error, :provider_operation_uncertain} =
             LegacyDeletion.complete(operation.id, {:returned, :ok})

    assert Repo.reload!(operation).holds_slot
    assert Repo.reload!(c.sandbox).terminated_at == nil
  end

  test "confirmed deletion remains idempotent without a second request", c do
    expect(Managoat.Sandbox, :destroy_once, fn _, _ -> :ok end)
    assert :ok = LegacyDeletion.destroy(c.sandbox, c.handle)
    operation = Repo.one!(SandboxOperation)
    confirmed_at = Repo.reload!(c.sandbox).terminated_at
    reject(Managoat.Sandbox, :destroy_once, 2)
    assert :ok = LegacyDeletion.destroy(Repo.reload!(c.sandbox), c.handle)
    assert Repo.reload!(operation).confirmed_at == operation.confirmed_at
    assert Repo.reload!(c.sandbox).terminated_at == confirmed_at
  end

  test "a deleted parent does not erase a causally confirmed cleanup obligation", c do
    {:ok, operation} = LegacyDeletion.submit(c.sandbox, c.handle)
    {:ok, _} = LegacyDeletion.claim(operation.id)
    Repo.delete!(c.parent)
    assert :ok = LegacyDeletion.complete(operation.id, {:returned, :ok})
    refute Repo.reload!(operation).holds_slot
  end

  test "dispatch has one durable claim and completion requires that claim", c do
    {:ok, operation} = LegacyDeletion.submit(c.sandbox, c.handle)

    assert {:error, :provider_operation_fenced} =
             LegacyDeletion.complete(operation.id, {:returned, :ok})

    assert {:ok, started} = LegacyDeletion.claim(operation.id)
    assert started.delete_started_at
    assert {:error, :provider_operation_fenced} = LegacyDeletion.claim(operation.id)
    reject(Managoat.Sandbox, :destroy_once, 2)
    assert {:error, :provider_operation_fenced} = LegacyDeletion.dispatch(operation.id)
    assert Repo.reload!(operation).holds_slot
  end

  test "a logical alias cannot authorize deletion or resume of another row's machine", c do
    other =
      insert_sandbox(
        user_id: insert_verified_user().id,
        sprite_name: c.sandbox.sprite_name,
        status: "ready"
      )

    reject(Managoat.Sandbox, :destroy_once, 2)
    assert {:error, :ownership_changed} = LegacyDeletion.destroy(c.sandbox, c.handle)
    assert {:error, :ownership_changed} = LegacyResume.submit(c.context, c.sandbox)
    assert Repo.reload!(other).status == "ready"
    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  test "the provider name remains reserved after logical row deletion", c do
    {:ok, operation} = LegacyDeletion.submit(c.sandbox, c.handle)
    Repo.delete!(c.sandbox)

    replacement =
      insert_sandbox(user_id: c.user.id, sprite_name: c.sandbox.sprite_name, status: "pending")

    parent =
      insert_conversation(
        user_id: c.user.id,
        sandbox: replacement,
        runtime: "claude",
        status: "pending"
      )

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_submit_create(replacement, parent)

    reject(Managoat.Sandbox, :destroy_once, 2)
    assert {:error, :ownership_changed} = LegacyDeletion.dispatch(operation.id)
    assert Repo.reload!(operation).delete_started_at == nil
    assert Repo.reload!(operation).holds_slot
  end

  test "an expired saved intent cannot start provider work or release existing capacity", c do
    {:ok, operation} = LegacyDeletion.submit(c.sandbox, c.handle, timeout_ms: 1)

    Process.sleep(
      max(DateTime.diff(operation.delete_deadline_at, DateTime.utc_now(), :millisecond), 0) + 2
    )

    reject(Managoat.Sandbox, :destroy_once, 2)
    assert {:error, :provider_operation_fenced} = LegacyDeletion.dispatch(operation.id)
    assert Repo.reload!(operation).state == "refused"
    assert Repo.reload!(operation).delete_started_at == nil
    assert Repo.reload!(operation).holds_slot
    assert Repo.reload!(c.sandbox).terminated_at == nil
  end
end
