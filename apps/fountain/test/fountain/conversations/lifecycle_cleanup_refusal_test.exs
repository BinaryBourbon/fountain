defmodule Fountain.Conversations.LifecycleCleanupRefusalTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{LegacyResume, Lifecycle, LogEvent, WakeContext}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "suspended")

    parent =
      insert_conversation(user_id: user.id, sandbox: sandbox, runtime: "claude", status: "idle")

    {:ok, context} = WakeContext.new(parent, nil)
    handle = Managoat.Sandbox.build_handle(:sprites, sandbox.sprite_name)
    %{user: user, sandbox: sandbox, parent: parent, context: context, handle: handle}
  end

  test "termination cannot retire a sandbox whose resume is unresolved", c do
    {:ok, operation} = LegacyResume.submit(c.context, c.sandbox)
    reject(Managoat.Sandbox, :destroy, 1)

    assert {:error, :provider_operation_fenced} =
             Lifecycle.terminate_machine(c.sandbox.id, c.parent.id, c.handle)

    assert Repo.reload!(c.sandbox).status == "suspended"
    assert Repo.reload!(operation).state == "submitted"
    assert Repo.reload!(operation).holds_slot
  end

  test "refused bound cleanup keeps the connection and publishes no reclaimed event", c do
    {:ok, operation} = LegacyResume.submit(c.context, c.sandbox)
    reject(Managoat.Sandbox, :destroy, 1)

    state = %{
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id,
      user_id: c.user.id,
      handle: c.handle
    }

    drop_connection = fn _, _ -> flunk("refused cleanup dropped the actor connection") end
    assert {:noreply, ^state} = Lifecycle.destroy_server(state, :idle, drop_connection)
    assert Repo.reload!(c.sandbox).status == "suspended"
    assert Repo.reload!(operation).holds_slot
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "an uncertain delete does not publish a confirmation timestamp", c do
    expect(Managoat.Sandbox, :destroy_once, fn _, _ -> {:error, {:unavailable, :timeout}} end)

    assert {:error, :provider_operation_uncertain} =
             Lifecycle.terminate_machine(c.sandbox.id, c.parent.id, c.handle)

    assert Repo.reload!(c.sandbox).status == "terminated"
    assert Repo.reload!(c.sandbox).terminated_at == nil
  end
end
