defmodule Fountain.Conversations.ConversationServerStoppedActorTest do
  use Fountain.ConversationServerCase

  test "shutdown after an unavailable failure decision cannot authorize another create" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    on_exit(fn -> Application.delete_env(:fountain, :provision_deadline_ms) end)
    handle = stub_happy_sprite()
    owner = self()

    stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      send(owner, {:created, self()})
      {:ok, handle}
    end)

    stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _opts ->
      send(owner, {:destroyed, self()})
      :ok
    end)

    stub(Fountain.Conversations.Provisioning, :install_packages, fn _, _, _, _ ->
      {:error, :offline_setup_failure}
    end)

    stub(Fountain.Workers.WebhookDelivery, :enqueue, fn endpoint, payload ->
      if payload["type"] == "conversation.provision.failed" do
        send(owner, {:failure_unavailable, self()})
        {:error, :unavailable}
      else
        Mimic.call_original(Fountain.Workers.WebhookDelivery, :enqueue, [endpoint, payload])
      end
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    {:ok, _} = Fountain.Webhooks.create_endpoint(user.id, %{"url" => "https://example.test/hook"})

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    {:ok, original} = GenServer.start(ConversationServer, args)
    on_exit(fn -> if Process.alive?(original), do: Process.exit(original, :kill) end)
    assert_receive {:created, ^original}, 5_000
    assert_receive {:failure_unavailable, ^original}, 5_000
    original_claim = :sys.get_state(original).actor_claim
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "starting"
    GenServer.stop(original, :shutdown)
    assert Repo.get!(Fountain.Conversations.ActorClaim, original_claim).state == "stopped"
    refute_received {:destroyed, ^original}

    reject(Fountain.Crypto, :load_tenant_key, 1)
    {:ok, successor} = GenServer.start(ConversationServer, args)
    monitor = Process.monitor(successor)
    on_exit(fn -> if Process.alive?(successor), do: Process.exit(successor, :kill) end)
    # A refused successor stops before credentials or any provider operation.
    try do
      :sys.get_state(successor, 5_000)
    catch
      :exit, _ -> :ok
    end

    operations =
      Enum.filter([:destroyed, :created], fn action ->
        receive do
          {^action, ^successor} -> true
        after
          0 -> false
        end
      end)

    assert operations == []
    assert_receive {:DOWN, ^monitor, :process, ^successor, :normal}, 5_000
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "starting"
  end
end
