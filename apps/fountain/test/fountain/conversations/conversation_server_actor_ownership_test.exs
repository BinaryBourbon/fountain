defmodule Fountain.Conversations.ConversationServerActorOwnershipTest do
  use Fountain.ConversationServerCase

  test "a duplicate actor cannot destroy or recreate the live actor's provisioning machine" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    on_exit(fn -> Application.delete_env(:fountain, :provision_deadline_ms) end)
    handle = stub_happy_sprite()
    owner = self()

    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ ->
      send(owner, {:credentials_loaded, self()})
      {:ok, <<0::256>>}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      send(owner, {:created, self()})
      {:ok, handle}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _opts ->
      send(owner, {:destroyed, self()})
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _, _, _, _ ->
      send(owner, {:setup_waiting, self()})

      receive do
        :finish_setup -> :ok
      after
        10_000 -> raise "setup barrier was not released"
      end
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    {:ok, original} = GenServer.start(ConversationServer, args)
    on_exit(fn -> if Process.alive?(original), do: Process.exit(original, :kill) end)
    assert_receive {:created, ^original}, 5_000
    assert_received {:credentials_loaded, ^original}
    assert_receive {:setup_waiting, ^original}, 5_000
    Fountain.Conversations.Redaction.put(conv.id, ["local-redaction-fixture"])
    on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

    # Horde's registry is eventually consistent; separate nodes can start
    # both actors before merging. Start both real callbacks explicitly here.
    {:ok, duplicate} = GenServer.start(ConversationServer, args)
    on_exit(fn -> if Process.alive?(duplicate), do: Process.exit(duplicate, :kill) end)
    monitor = Process.monitor(duplicate)

    assert_receive {:DOWN, ^monitor, :process, ^duplicate, :normal}, 5_000
    refute_received {:destroyed, _}
    refute_received {:created, _}
    refute_received {:credentials_loaded, ^duplicate}

    assert Fountain.Conversations.Redaction.redact(conv.id, "local-redaction-fixture") ==
             "[REDACTED]"

    assert Process.alive?(original)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "starting"
    send(original, :finish_setup)
    assert :sys.get_state(original, 5_000).sandbox_id == conv.sandbox_id
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
  end

  test "clean actor shutdown permits reattach without another machine creation" do
    stub_happy_sprite()
    owner = self()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    {original, _, :alive} = start_server(conv)
    original_claim = :sys.get_state(original).actor_claim
    GenServer.stop(original, :shutdown)
    assert Repo.get!(Fountain.Conversations.ActorClaim, original_claim).state == "stopped"

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      send(owner, :unexpected_create)
      {:error, :unexpected_create}
    end)

    {successor, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(successor), do: GenServer.stop(successor) end)
    refute :sys.get_state(successor).actor_claim == original_claim
    refute_received :unexpected_create
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
  end

  test "duplicate startup cannot interrupt the current actor's bounded execution" do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    {original, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(original), do: GenServer.stop(original) end)
    {:ok, receipt} = Fountain.Conversations.PromptDelivery.submit(user.id, conv.id, "Review", [])

    {:ok, turn} =
      Fountain.Conversations.PromptDelivery._unsafe_activate(conv.id, receipt.id, conv.sandbox_id)

    {:ok, execution} =
      Fountain.Conversations.ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {:ok, duplicate} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    monitor = Process.monitor(duplicate)
    assert_receive {:DOWN, ^monitor, :process, ^duplicate, :normal}, 5_000
    assert Repo.reload!(turn).status == "running"
    assert Repo.reload!(receipt).state == "claimed"
    assert Repo.reload!(execution).state == "active"
    assert Process.alive?(original)
  end

  test "a ready transition after the initial read selects reattach instead of fresh creation" do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    {:ok, first_read} = Agent.start_link(fn -> true end)
    reject(Managoat.Sandbox.Sprites, :create, 2)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    stub(Conversations, :_unsafe_get_sandbox, fn id ->
      observed = Mimic.call_original(Conversations, :_unsafe_get_sandbox, [id])

      if id == conv.sandbox_id && Agent.get_and_update(first_read, &{&1, false}) do
        assert observed.status == "pending"
        # The actor already read pending, but readiness commits before its
        # claim transaction. Only the locked snapshot may choose provisioning.
        observed |> change(status: "ready") |> Repo.update!()
      end

      observed
    end)

    {pid, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert :sys.get_state(pid).sandbox_id == conv.sandbox_id
    assert Repo.get!(Conversations.Sandbox, conv.sandbox_id).status == "ready"
  end
end
