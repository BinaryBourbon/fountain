defmodule Fountain.Conversations.ConversationServerReprovisionTest do
  # A machine left starting may still exist at the provider. Neither registry
  # absence nor process exit authorizes another create, adoption or deletion.
  use Fountain.ConversationServerCase

  alias Fountain.Conversations

  test "an unclaimed starting row is retained without credentials or provider calls" do
    stub_happy_sprite()
    reject(Fountain.Crypto, :load_tenant_key, 1)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    reject(Managoat.Sandbox.Sprites, :create, 2)
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "starting"})

    {_pid, ref, :stopped} = start_server(conv)
    assert :normal = assert_stopped(ref)
    assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "starting"
    assert Repo.aggregate(Conversations.ActorClaim, :count) == 0
  end

  test "a new pending row provisions without destroying anything" do
    stub_happy_sprite()
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "pending"

    {pid, _ref, :alive} = start_server(conv)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
    GenServer.stop(pid, :shutdown)
  end

  test "the interrupted provision helper cannot delete or recreate an unmanaged machine" do
    stub_happy_sprite()
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    reject(Managoat.Sandbox.Sprites, :create, 2)
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "starting"})

    assert {:error, :provider_operation_fenced} =
             Conversations.Provisioning.discard_interrupted_attempt(:sprites, sandbox, true)

    assert {:error, :provider_operation_fenced} =
             Conversations.Provisioning.create_sandbox_handle(:sprites, sandbox, conv)

    assert Repo.reload!(sandbox).status == "starting"
  end
end
