defmodule Fountain.Conversations.ProviderWakeAuthorityTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Conversations, Quotas}

  alias Fountain.Conversations.{
    ActorLaunches,
    LegacyResume,
    SandboxOperation,
    SandboxOperations,
    SandboxTransitions,
    WakeContext
  }

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "suspended")

    parent =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox: sandbox,
        runtime: agent.runtime,
        status: "idle"
      )

    {:ok, context} = WakeContext.new(parent, nil)
    %{user: user, sandbox: sandbox, parent: parent, context: context}
  end

  test "expired grant makes no provider call or capacity reservation", c do
    reject(Managoat.Sandbox, :resume, 1)
    expired = %{c.context | deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    assert {:error, :wake_expired} = LegacyResume.resume(expired, c.sandbox)
    assert Repo.aggregate(SandboxOperation, :count) == 0
    assert Quotas.fleet_count() == 0
  end

  test "resume commits its authority and capacity before provider I/O", c do
    expect(Managoat.Sandbox, :resume, fn handle ->
      refute Repo.in_transaction?()
      operation = Repo.one!(SandboxOperation)
      assert operation.state == "submitted"
      assert operation.holds_slot
      assert operation.conversation_id == c.parent.id
      assert operation.wake_deadline_at == c.context.deadline_at
      assert Quotas.fleet_count() == 1
      assert Repo.reload!(c.sandbox).status == "suspended"
      {:ok, handle}
    end)

    assert {:ok, ready} = LegacyResume.resume(c.context, c.sandbox)
    assert ready.status == "ready"
    assert Repo.one!(SandboxOperation).state == "confirmed"
    refute Repo.one!(SandboxOperation).holds_slot
    assert Quotas.fleet_count() == 1
    refute SandboxOperations._unsafe_managed?(ready.id)
  end

  test "unknown resume retains capacity and fences retry and destruction", c do
    expect(Managoat.Sandbox, :resume, fn _ -> {:error, :timeout} end)
    assert {:error, :provider_operation_uncertain} = LegacyResume.resume(c.context, c.sandbox)
    operation = Repo.one!(SandboxOperation)
    assert operation.state == "uncertain"
    assert operation.holds_slot
    assert Quotas.fleet_count() == 1

    assert {:error, :provider_operation_fenced} =
             LegacyResume.resume(c.context, Repo.reload!(c.sandbox))

    reject(Managoat.Sandbox, :destroy, 1)

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_destroy_or_legacy(Repo.reload!(c.sandbox), nil)
  end

  test "a provider error cannot impersonate a guaranteed unsent result", c do
    expect(Managoat.Sandbox, :resume, fn _ -> {:error, :wake_expired} end)
    assert {:error, :provider_operation_uncertain} = LegacyResume.resume(c.context, c.sandbox)
    assert Repo.one!(SandboxOperation).holds_slot
  end

  test "a timed-out provider task dies and leaves its reservation", c do
    {:ok, operation} = LegacyResume.submit(c.context, c.sandbox)
    owner = self()

    expect(Managoat.Sandbox, :resume, fn _ ->
      send(owner, {:provider, self()})
      receive do: (:never -> {:error, :unexpected})
    end)

    handle = Managoat.Sandbox.build_handle(:sprites, c.sandbox.sprite_name)
    result = WakeContext.run(c.context, fn -> Managoat.Sandbox.resume(handle) end, 1_000)
    assert {:error, :provider_operation_uncertain} = LegacyResume.complete(operation, result)
    assert_received {:provider, pid}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert Repo.one!(SandboxOperation).state == "uncertain"
    assert Quotas.fleet_count() == 1
  end

  test "receipt cancellation after the probe context refuses resume", c do
    {:ok, receipt} =
      Fountain.Conversations.PromptDelivery.submit(c.user.id, c.parent.id, "Review", [])

    {:ok, context} = WakeContext.new(c.parent, receipt.id)

    Fountain.Conversations.PromptDelivery.refuse(
      c.user.id,
      c.parent.id,
      receipt.id,
      "admission_refused",
      sandbox_id: c.sandbox.id
    )

    reject(Managoat.Sandbox, :resume, 1)
    assert {:error, :opening_cancelled} = LegacyResume.resume(context, c.sandbox)
    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  test "an expired actor startup blocks legacy provider work", c do
    expire_startup(c)
    reject(Managoat.Sandbox, :resume, 1)
    assert {:error, :startup_unresolved} = LegacyResume.resume(c.context, c.sandbox)
    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  test "changed parent binding refuses resume before I/O", c do
    replacement = insert_sandbox(user_id: c.user.id)
    c.parent |> Ecto.Changeset.change(sandbox_id: replacement.id) |> Repo.update!()
    reject(Managoat.Sandbox, :resume, 1)
    assert {:error, :ownership_changed} = LegacyResume.resume(c.context, c.sandbox)
    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  test "late causal success cannot start an actor beyond the original wake deadline", c do
    {:ok, operation} = LegacyResume.submit(c.context, c.sandbox)
    handle = Managoat.Sandbox.build_handle(:sprites, c.sandbox.sprite_name)
    assert {:ok, ready} = LegacyResume.complete(operation, {:returned, {:ok, handle}})
    expired = DateTime.add(DateTime.utc_now(), -1, :second)
    assert {:error, :launch_expired} = ActorLaunches.reconnect(c.parent, ready, nil, expired)
    assert Repo.reload!(operation).state == "confirmed"
    assert Quotas.fleet_count() == 1
  end

  test "resume completion cannot revive a deleted parent", c do
    {:ok, operation} = LegacyResume.submit(c.context, c.sandbox)
    Repo.delete!(c.parent)
    handle = Managoat.Sandbox.build_handle(:sprites, c.sandbox.sprite_name)

    assert {:error, :provider_operation_uncertain} =
             LegacyResume.complete(operation, {:returned, {:ok, handle}})

    assert Repo.reload!(operation).holds_slot
    assert Repo.reload!(c.sandbox).status == "suspended"
  end

  test "managed resume persists the original wake deadline and refuses an expired grant", c do
    {:ok, pending} = Conversations.update_sandbox(c.sandbox, %{status: "pending"})
    {:ok, creation} = SandboxOperations._unsafe_submit_create(pending, c.parent)

    handle = %{
      Managoat.Sandbox.build_handle(:sprites, pending.sprite_name)
      | instance_id: "saved-instance"
    }

    {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})
    {:ok, ready} = SandboxOperations._unsafe_finish_provision(pending, c.parent)
    {:ok, parked} = Conversations.update_sandbox(ready, %{status: "suspended"})
    expired = %{c.context | deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    reject(Managoat.Sandbox, :get, 1)
    assert {:error, :wake_expired} = SandboxTransitions._unsafe_resume(parked, expired)
    other = insert_sandbox(user_id: c.user.id, status: "suspended")

    other_parent =
      insert_conversation(user_id: c.user.id, sandbox: other, runtime: "claude", status: "idle")

    {:ok, other_context} = WakeContext.new(other_parent, nil)
    assert {:error, :ownership_changed} = SandboxTransitions._unsafe_resume(parked, other_context)
    assert {:ok, operation} = SandboxTransitions._unsafe_submit(parked, "resume", c.context)
    assert operation.wake_deadline_at == c.context.deadline_at
    assert operation.conversation_id == c.parent.id
    assert operation.creation_id == creation.id
    assert Repo.reload!(creation).holds_slot

    {:ok, ready} =
      SandboxTransitions._unsafe_complete(
        operation.id,
        {:ok, %{raw: %{"id" => "saved-instance"}}},
        :wake
      )

    expire_startup(c)

    assert {:error, :startup_unresolved} =
             SandboxTransitions._unsafe_verify_ready(ready, c.context)

    {:ok, parked} = Conversations.update_sandbox(ready, %{status: "suspended"})
    # The active actor claim is refused by the earlier turn-admission fence.
    assert {:error, :sandbox_mid_turn} = SandboxTransitions._unsafe_resume(parked, c.context)
    assert Repo.aggregate(from(o in SandboxOperation, where: o.action == "resume"), :count) == 1
  end

  defp expire_startup(c) do
    id = Ecto.UUID.generate()

    Repo.insert!(%Fountain.Conversations.ActorClaim{
      id: id,
      user_id: c.user.id,
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id
    })

    Repo.insert!(%Fountain.Conversations.ActorStartup{
      id: id,
      actor_claim_id: id,
      user_id: c.user.id,
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id,
      deadline_at: DateTime.add(DateTime.utc_now(), -1, :second),
      state: "expired",
      settled_at: DateTime.utc_now()
    })
  end
end
