defmodule Fountain.Conversations.SandboxOperationsTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Conversations, Quotas}
  alias Fountain.Conversations.{SandboxOperation, SandboxOperations}
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "pending", mode: "ephemeral")
    parent = insert_conversation(user_id: user.id, sandbox: sandbox)
    %{user: user, sandbox: sandbox, parent: parent}
  end

  defp handle(sandbox, id \\ Ecto.UUID.generate()) do
    %Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: id}
  end

  test "persists a reservation before exactly one fresh create outside locks", c do
    expected = handle(c.sandbox)

    expect(Managoat.Sandbox.Sprites, :create_new, fn name, _opts ->
      refute Repo.in_transaction?()
      assert name == c.sandbox.sprite_name
      assert [%{state: "submitted", holds_slot: true}] = Repo.all(SandboxOperation)
      assert Quotas.active_sandbox_count(c.user.id) == 1
      {:ok, expected}
    end)

    assert {:ok, ^expected} = SandboxOperations._unsafe_create(c.sandbox, c.parent)
    assert [%{state: "confirmed", provider_instance_id: id}] = Repo.all(SandboxOperation)
    assert id == expected.instance_id
    assert Quotas.active_sandbox_count(c.user.id) == 1
    assert Quotas.active_sandbox_counts() == %{c.user.id => 1}

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_create(c.sandbox, c.parent)
  end

  test "an uncertain create cannot be retried or excluded from either quota", c do
    expect(Managoat.Sandbox.Sprites, :create_new, fn _, _ ->
      {:error, {:unavailable, :timeout}}
    end)

    assert {:error, :provider_operation_uncertain} =
             SandboxOperations._unsafe_create(c.sandbox, c.parent)

    assert {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "failed"})
    assert Quotas.active_sandbox_count(c.user.id, exclude: c.sandbox.id) == 1
    assert Quotas.active_sandbox_counts() == %{c.user.id => 1}
    assert Quotas.fleet_count() == 1

    assert {:error, :sandbox_retired} = SandboxOperations._unsafe_create(c.sandbox, c.parent)
    assert [%{state: "uncertain", holds_slot: true}] = Repo.all(SandboxOperation)
  end

  test "an interrupted attempt has no fresh grant and cannot adopt a later lookup", c do
    {:ok, starting} = Conversations.update_sandbox(c.sandbox, %{status: "starting"})

    assert {:error, :provider_operation_uncertain} =
             SandboxOperations._unsafe_create(starting, c.parent)

    assert [operation] = Repo.all(SandboxOperation)
    assert operation.state == "uncertain"
    assert operation.submitted_at == nil

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_complete_create(operation.id, {:ok, handle(c.sandbox)})
  end

  test "late create success retains identity and capacity after parent deletion", c do
    assert {:ok, operation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    Repo.delete!(c.parent)
    Repo.delete!(c.sandbox)
    expected = handle(c.sandbox)

    assert {:error, :sandbox_retired} =
             SandboxOperations._unsafe_complete_create(operation.id, {:ok, expected})

    saved = Repo.get!(SandboxOperation, operation.id)
    assert saved.provider_instance_id == expected.instance_id
    assert saved.state == "confirmed"
    assert saved.holds_slot
    assert Quotas.active_sandbox_count(c.user.id) == 1
    assert Quotas.fleet_count() == 1
  end

  test "a physical name remains claimed after its owning rows are deleted", c do
    assert {:ok, _} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    Repo.delete!(c.parent)
    Repo.delete!(c.sandbox)

    successor =
      insert_sandbox(
        user_id: c.user.id,
        status: "pending",
        mode: "ephemeral",
        sprite_name: c.sandbox.sprite_name
      )

    parent = insert_conversation(user_id: c.user.id, sandbox: successor)

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_submit_create(successor, parent)

    assert Quotas.active_sandbox_count(c.user.id) == 2
  end

  test "a late causal reply can settle an observer timeout without another create", c do
    assert {:ok, operation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    assert {:ok, _} = SandboxOperations._unsafe_mark_uncertain(operation.id)
    expected = handle(c.sandbox)

    assert {:ok, ^expected} =
             SandboxOperations._unsafe_complete_create(operation.id, {:ok, expected})

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_mark_uncertain(operation.id)

    assert Repo.get!(SandboxOperation, operation.id).state == "confirmed"
  end

  test "conflicting provider identity retains uncertainty rather than adopting it", c do
    first = handle(c.sandbox, "provider-instance")
    assert {:ok, operation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)

    assert {:ok, _} =
             SandboxOperations._unsafe_complete_create(operation.id, {:ok, first})

    other = insert_sandbox(user_id: c.user.id, status: "pending", mode: "ephemeral")
    parent = insert_conversation(user_id: c.user.id, sandbox: other)
    assert {:ok, operation} = SandboxOperations._unsafe_submit_create(other, parent)

    assert {:error, :provider_operation_uncertain} =
             SandboxOperations._unsafe_complete_create(
               operation.id,
               {:ok, handle(other, first.instance_id)}
             )

    assert %{state: "uncertain", provider_instance_id: nil, holds_slot: true} =
             Repo.get!(SandboxOperation, operation.id)
  end

  test "a refused create keeps the name claim but releases its provider reservation", c do
    assert {:ok, operation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)

    assert {:error, :provider_create_refused} =
             SandboxOperations._unsafe_complete_create(operation.id, {:error, :already_exists})

    assert {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "failed"})
    assert Quotas.active_sandbox_count(c.user.id) == 0
    assert SandboxOperations._unsafe_managed?(c.sandbox.id)
  end

  test "a response naming a different machine cannot establish identity", c do
    assert {:ok, operation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    wrong = %{handle(c.sandbox) | name: "another-machine"}

    assert {:error, :provider_operation_uncertain} =
             SandboxOperations._unsafe_complete_create(operation.id, {:ok, wrong})

    assert Repo.get!(SandboxOperation, operation.id).provider_instance_id == nil
  end

  test "ownership drift is refused before any provider request", c do
    foreign = insert_verified_user()
    c.parent |> Ecto.Changeset.change(user_id: foreign.id) |> Repo.update!()

    assert {:error, :ownership_changed} = SandboxOperations._unsafe_create(c.sandbox, c.parent)
    assert Repo.all(SandboxOperation) == []
  end

  defp confirmed_create(c) do
    {:ok, operation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    {:ok, _} = SandboxOperations._unsafe_complete_create(operation.id, {:ok, handle(c.sandbox)})
    Repo.get!(SandboxOperation, operation.id)
  end

  test "delete intent retires admission before I/O and holds capacity until acknowledgement", c do
    creation = confirmed_create(c)

    expect(Managoat.Sandbox.Sprites, :destroy_once, fn handle, _opts ->
      refute Repo.in_transaction?()
      assert handle.instance_id == creation.provider_instance_id
      assert handle.name == c.sandbox.sprite_name
      assert %{status: "terminated", terminated_at: nil} = Repo.reload!(c.sandbox)
      assert Quotas.active_sandbox_count(c.user.id) == 1
      assert Repo.get_by!(SandboxOperation, action: "destroy").state == "submitted"
      :ok
    end)

    assert :ok = SandboxOperations._unsafe_destroy(c.sandbox, holder: c.parent.id)
    assert Quotas.active_sandbox_count(c.user.id) == 0
    assert Repo.reload!(c.sandbox).terminated_at
    refute Repo.reload!(creation).holds_slot
    assert :ok = SandboxOperations._unsafe_destroy(c.sandbox, holder: c.parent.id)
  end

  test "uncertain delete keeps capacity and an open interval without replay", c do
    creation = confirmed_create(c)
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> {:error, :timeout} end)

    assert {:error, :provider_operation_uncertain} = SandboxOperations._unsafe_destroy(c.sandbox)
    assert %{status: "terminated", terminated_at: nil} = Repo.reload!(c.sandbox)
    assert Quotas.fleet_count() == 1
    assert {:error, :provider_operation_fenced} = SandboxOperations._unsafe_destroy(c.sandbox)

    operation = Repo.get_by!(SandboxOperation, action: "destroy")
    assert :ok = SandboxOperations._unsafe_complete_destroy(operation.id, :ok)
    at = Repo.reload!(c.sandbox).terminated_at
    assert at
    refute Repo.reload!(creation).holds_slot
    assert Quotas.fleet_count() == 0

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_complete_destroy(operation.id, :ok)

    assert Repo.reload!(c.sandbox).terminated_at == at
  end

  test "a deletion acknowledgement can settle after both parent rows disappear", c do
    creation = confirmed_create(c)
    {:ok, deletion} = SandboxOperations._unsafe_submit_destroy(c.sandbox)
    Repo.delete!(c.parent)
    Repo.delete!(Repo.reload!(c.sandbox))
    assert Quotas.fleet_count() == 1
    assert :ok = SandboxOperations._unsafe_complete_destroy(deletion.id, {:error, :not_found})
    refute Repo.reload!(creation).holds_slot
    assert Quotas.fleet_count() == 0
  end

  test "unconfirmed creation cannot authorize name-based deletion", c do
    {:ok, creation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    assert {:error, :provider_identity_missing} = SandboxOperations._unsafe_destroy(c.sandbox)
    assert Repo.reload!(creation).holds_slot
    refute Repo.get_by(SandboxOperation, action: "destroy")
  end

  test "another live holder refuses deletion without retiring its sandbox", c do
    confirmed_create(c)
    insert_conversation(user_id: c.user.id, sandbox: c.sandbox)

    assert {:error, :sandbox_held} =
             SandboxOperations._unsafe_destroy(c.sandbox, holder: c.parent.id)

    assert Repo.reload!(c.sandbox).status == "pending"
    refute Repo.get_by(SandboxOperation, action: "destroy")
  end

  test "delete rechecks retained ownership before provider access", c do
    confirmed_create(c)
    foreign = insert_verified_user()
    observed = %{c.sandbox | user_id: foreign.id}
    assert {:error, :ownership_changed} = SandboxOperations._unsafe_destroy(observed)
    refute Repo.get_by(SandboxOperation, action: "destroy")
  end

  test "uncertain provider time survives logical retirement and deleted parents", c do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    started = DateTime.add(now, -600, :second)
    c.sandbox |> Ecto.Changeset.change(inserted_at: started) |> Repo.update!()
    confirmed_create(c)
    {:ok, operation} = SandboxOperations._unsafe_submit_destroy(c.sandbox)
    {:ok, _} = SandboxOperations._unsafe_mark_uncertain(operation.id)

    report = fn ceiling ->
      Fountain.Billing.SandboxUsage.attribution(started, ceiling,
        now: ceiling,
        user_id: c.user.id
      )
    end

    assert [%{active_seconds: 600, sandboxes: 1}] = report.(now)
    Repo.delete!(c.parent)
    Repo.delete!(Repo.reload!(c.sandbox))
    assert [%{active_seconds: 600, sandboxes: 1}] = report.(now)
    assert :ok = SandboxOperations._unsafe_complete_destroy(operation.id, :ok)
    # A confirmed end is retained in the journal after the logical row is gone.
    [at_confirmation] = report.(DateTime.add(now, 3600, :second))
    assert at_confirmation.active_seconds in 600..610
    assert [^at_confirmation] = report.(DateTime.add(now, 7200, :second))
  end

  test "bounded provisioning uses fresh creation and binds identity before readiness", c do
    parent = %{c.parent | execution_limits: %{"wall_time_seconds" => 60}}
    expected = handle(c.sandbox)
    expect(Managoat.Sandbox.Sprites, :create_new, fn _, _ -> {:ok, expected} end)

    assert {:ok, ^expected} =
             Conversations.Provisioning.create_sandbox_handle(:sprites, c.sandbox, parent)

    assert {:ok, ready} = Conversations.Provisioning.finish_provision(c.sandbox, parent)
    assert ready.status == "ready"
    assert ready.provider_instance_id == expected.instance_id
  end

  test "managed cleanup and interrupted provisioning cannot downgrade to legacy writes", c do
    {:ok, _} = SandboxOperations._unsafe_submit_create(c.sandbox, c.parent)
    reject(Managoat.Sandbox, :destroy, 1)
    reject(Managoat.Sandbox, :create, 2)

    assert {:error, :provider_identity_missing} =
             SandboxOperations._unsafe_destroy_or_legacy(c.sandbox, handle(c.sandbox))

    assert {:error, :provider_operation_fenced} =
             Conversations.Provisioning.discard_interrupted_attempt(:sprites, c.sandbox, true)

    assert {:error, :provider_operation_fenced} =
             Conversations.Provisioning.create_sandbox_handle(:sprites, c.sandbox, c.parent)
  end

  test "retired parent refuses ready publication while retaining cleanup identity", c do
    creation = confirmed_create(c)
    c.parent |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()

    assert {:error, :sandbox_retired} =
             Conversations.Provisioning.finish_provision(c.sandbox, c.parent)

    assert Repo.reload!(c.sandbox).status == "pending"
    assert Repo.reload!(creation).holds_slot
  end
end
