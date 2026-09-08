defmodule Fountain.Conversations.PromptDeliveryActorTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{PromptDelivery, PromptDeliveryActor, Turn, TurnImage}

  test "creation delivers its saved opening turn once through the real actor" do
    stub_happy_sprite()
    owner = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, _ ->
      send(owner, :opening_provider_attempt)
      {:error, {:unavailable, :offline_test_stop}}
    end)

    Mimic.stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      args = Keyword.put(args, :runtime_module, Managoat.Runtimes.Testing.FakeRuntime)
      {:ok, pid} = GenServer.start(ConversationServer, args)
      send(owner, {:opening_actor, pid})
      {:ok, pid}
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    image = %{media_type: "image/png", data: <<0, 1, 2>>}

    assert {:ok, conv} =
             Conversations.start_conversation(%{
               "user_id" => user.id,
               "agent_id" => agent.id,
               "prompt" => "Review opening image",
               "images" => [image]
             })

    assert_receive {:opening_actor, pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive :opening_provider_attempt, 5_000
    :sys.get_state(pid)

    receipt = Repo.one!(Fountain.Conversations.PromptReceipt)
    assert receipt.conversation_id == conv.id
    assert receipt.state == "claimed"
    assert Repo.get!(Turn, receipt.turn_id).prompt == "Review opening image"
    assert Repo.one!(TurnImage).data == image.data
    ConversationServer.queue_prompt_receipt(pid, receipt.id)
    :sys.get_state(pid)
    refute_receive :opening_provider_attempt
    assert Repo.aggregate(Turn, :count) == 1
    assert Repo.aggregate(TurnImage, :count) == 1
  end

  test "startup delivers a durable receipt once even when its notification was lost" do
    stub_happy_sprite()
    owner = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, _ ->
      send(owner, :provider_attempt)
      {:error, {:unavailable, :offline_test_stop}}
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    image = %{media_type: "image/png", data: <<0, 1, 2>>}
    {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "Review image", [image])
    {pid, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive :provider_attempt, 5_000
    # A call is a mailbox barrier after the delivery cast.
    :sys.get_state(pid)
    assert Repo.reload!(receipt).state == "claimed"
    assert Repo.get!(Turn, receipt.turn_id).status == "failed"
    assert Repo.one!(TurnImage).data == image.data
    assert Repo.aggregate(Turn, :count) == 1
    ConversationServer.queue_prompt_receipt(pid, receipt.id)
    ConversationServer.queue_prompt_receipt(pid, receipt.id)
    :sys.get_state(pid)
    refute_receive :provider_attempt
    assert Repo.aggregate(Turn, :count) == 1
    assert Repo.aggregate(TurnImage, :count) == 1
  end

  test "the persisted job reaches an already running actor after the initial signal is lost" do
    stub_happy_sprite()
    owner = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, _ ->
      send(owner, :provider_attempt)
      {:error, {:unavailable, :offline_test_stop}}
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    Managoat.Runtimes.Testing.FakeRuntime.observe(self())

    {:ok, pid} =
      GenServer.start(
        ConversationServer,
        [
          conversation_id: conv.id,
          sandbox_id: conv.sandbox_id,
          runtime_module: Managoat.Runtimes.Testing.FakeRuntime
        ],
        name: ConversationServer.via(conv.id)
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    :sys.get_state(pid)
    assert ConversationServer.whereis(conv.id) == pid
    refute_receive :provider_attempt

    {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "Review after startup", [])
    # No cast from the submitter. Only the durable job reaches the real actor.
    [job] = all_enqueued(worker: Fountain.Workers.PromptDispatch)
    assert {:snooze, 15} = perform_job(Fountain.Workers.PromptDispatch, job.args)
    assert_receive :provider_attempt, 5_000
    :sys.get_state(pid)
    assert :ok = perform_job(Fountain.Workers.PromptDispatch, job.args)
    refute_receive :provider_attempt
    assert Repo.reload!(receipt).state == "claimed"
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "a stale actor's busy state cannot refuse a replacement's pending receipt" do
    user = insert_verified_user()
    old = insert_sandbox(user_id: user.id, status: "ready")
    replacement = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: old, status: "idle")
    {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "Review", [])
    {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})

    state = %{
      user_id: user.id,
      conversation_id: conv.id,
      sandbox_id: old.id,
      current_turn: %Turn{status: "running", origin: "user"},
      inference_source: :own
    }

    close = fn _ -> flunk("a busy actor must not close another turn") end
    run = fn _, _, _, _, _ -> flunk("stale actor must not run a prompt") end
    assert {:noreply, ^state} = PromptDeliveryActor.deliver(state, receipt.id, close, run)
    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
  end

  test "a current actor records admission refusal instead of dropping an accepted prompt" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "Review", [])

    state = %{
      user_id: user.id,
      conversation_id: conv.id,
      sandbox_id: sandbox.id,
      current_turn: %Turn{status: "running", origin: "user"},
      inference_source: :own
    }

    assert {:noreply, ^state} =
             PromptDeliveryActor.deliver(
               state,
               receipt.id,
               fn _ -> flunk("must not close a busy turn") end,
               fn _, _, _, _, _ -> flunk("must not start another turn") end
             )

    assert Repo.reload!(receipt).failure_reason == "admission_refused"
    assert Repo.get!(Turn, receipt.turn_id).status == "failed"
  end
end
