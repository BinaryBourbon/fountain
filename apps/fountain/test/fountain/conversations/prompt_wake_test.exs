defmodule Fountain.Conversations.PromptWakeTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{PromptDelivery, PromptWake, PromptWakeRequest, Turn}
  alias Fountain.Workers.PromptDispatch

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    conv =
      insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox, status: "idle")

    %{user: user, sandbox: sandbox, conv: conv}
  end

  defp abandon_before_delivery(c) do
    owner = self()

    stub(ConversationServer, :whereis, fn _ ->
      send(owner, {:accepted_before_delivery, self()})
      receive do: (:continue -> nil)
    end)

    caller =
      spawn(fn ->
        PromptDelivery.accept(c.user.id, c.conv.id, "Review", [], idempotency_key: "saved")
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    monitor = Process.monitor(caller)
    assert_receive {:accepted_before_delivery, ^caller}, 5_000
    receipt = PromptDelivery.queued(c.user.id, c.conv.id)
    assert receipt
    [job] = all_enqueued(worker: PromptDispatch)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    stub(ConversationServer, :whereis, fn _ -> nil end)
    {receipt, job}
  end

  test "dispatch starts the saved wake when its submitter dies before delivery", c do
    {receipt, job} = abandon_before_delivery(c)
    assert Repo.get!(PromptWakeRequest, receipt.id).state == "requested"
    owner = self()

    expect(Conversations, :_unsafe_wake_bound_conversation, fn saved ->
      assert saved.id == c.conv.id
      assert saved.sandbox_id == c.sandbox.id
      assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"
      refute Repo.in_transaction?()
      send(owner, :wake_started)
      {:error, :provisioning}
    end)

    assert {:snooze, 15} = perform_job(PromptDispatch, job.args)
    assert_receive :wake_started
    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(PromptWakeRequest, receipt.id).state == "returned"
    assert {:snooze, 15} = perform_job(PromptDispatch, job.args)

    assert {:ok, %{id: id}} =
             PromptDelivery.accept(c.user.id, c.conv.id, "Review", [], idempotency_key: "saved")

    assert id == receipt.id
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "saved dispatch reaches real actor startup on the original ready machine", c do
    {receipt, job} = abandon_before_delivery(c)
    stub_happy_sprite(c.sandbox.sprite_name)
    reject(Managoat.Sandbox.Sprites, :create, 2)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    owner = self()

    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      assert args[:sandbox_id] == c.sandbox.id
      refute Keyword.has_key?(args, :initial_prompt)

      {:ok, pid} =
        GenServer.start(
          ConversationServer,
          Keyword.put(args, :runtime_module, Managoat.Runtimes.Testing.FakeRuntime)
        )

      send(owner, {:actor_started, pid})
      {:ok, pid}
    end)

    assert {:snooze, 15} = perform_job(PromptDispatch, job.args)
    assert_receive {:actor_started, pid}, 5_000
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    state = :sys.get_state(pid, 5_000)
    assert state.sandbox_id == c.sandbox.id
    assert state.actor_claim
    assert Repo.reload!(c.sandbox).status == "ready"
    assert Repo.reload!(receipt).state == "claimed"
    assert :ok = perform_job(PromptDispatch, job.args)
  end

  test "death after claiming wake preserves uncertainty and never repeats provider entry", c do
    {receipt, job} = abandon_before_delivery(c)
    owner = self()

    expect(Conversations, :_unsafe_wake_bound_conversation, fn _ ->
      send(owner, {:wake_in_progress, self()})
      receive do: (:continue -> {:ok, c.conv})
    end)

    caller = spawn(fn -> PromptWake.deliver(receipt) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    monitor = Process.monitor(caller)
    assert_receive {:wake_in_progress, ^caller}, 5_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

    assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"
    assert {:snooze, 15} = perform_job(PromptDispatch, job.args)

    assert {:ok, _} =
             PromptDelivery.accept(c.user.id, c.conv.id, "Review", [], idempotency_key: "saved")

    assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"
  end

  test "an interrupted earlier wake also fences a different receipt", c do
    {receipt, _job} = abandon_before_delivery(c)
    expect(Conversations, :_unsafe_wake_bound_conversation, fn _ -> raise "lost wake reply" end)
    assert_raise RuntimeError, "lost wake reply", fn -> PromptWake.deliver(receipt) end
    assert {:ok, _} = PromptDelivery.refuse(c.user.id, c.conv.id, receipt.id, "cancelled")
    assert {:ok, next} = PromptDelivery.accept(c.user.id, c.conv.id, "New prompt", [])
    assert Repo.get!(PromptWakeRequest, next.id).state == "requested"
    assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"
  end

  test "cancellation or expiry before dispatch authorizes no wake", c do
    {receipt, job} = abandon_before_delivery(c)
    reject(Conversations, :_unsafe_wake_bound_conversation, 1)
    assert {:ok, _} = PromptDelivery.refuse(c.user.id, c.conv.id, receipt.id, "cancelled")
    assert :ok = perform_job(PromptDispatch, job.args)
    assert Repo.get!(PromptWakeRequest, receipt.id).started_at == nil

    assert {:ok, next} = PromptDelivery.submit(c.user.id, c.conv.id, "Expired", [])
    assert {:ok, _} = Repo.transaction(fn -> PromptWake.save!(Repo.reload!(c.conv), next) end)
    next |> change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()
    # A stale notification still has to re-read the deadline under its locks.
    assert :ok = PromptWake.deliver(next)
    assert Repo.get!(PromptWakeRequest, next.id).started_at == nil
  end

  test "a moved parent or forged tenant cannot spend the saved wake", c do
    {receipt, job} = abandon_before_delivery(c)
    reject(Conversations, :_unsafe_wake_bound_conversation, 1)
    other = insert_verified_user()
    assert :ok = PromptWake.deliver(%{receipt | user_id: other.id})
    replacement = insert_sandbox(user_id: c.user.id, agent_id: c.conv.agent_id, status: "ready")
    {:ok, _} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})
    assert {:snooze, 15} = perform_job(PromptDispatch, job.args)
    assert Repo.get!(PromptWakeRequest, receipt.id).started_at == nil
  end

  test "the bound wake entry point rejects a binding moved after dispatch claim", c do
    replacement = insert_sandbox(user_id: c.user.id, agent_id: c.conv.agent_id, status: "ready")
    {:ok, _} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert {:error, :ownership_changed} = Conversations._unsafe_wake_bound_conversation(c.conv)
  end

  test "a submitted-only receipt cannot gain wake authorization through retry", c do
    {:ok, receipt} =
      PromptDelivery.submit(c.user.id, c.conv.id, "Review", [], idempotency_key: "low-level")

    stub(ConversationServer, :whereis, fn _ -> nil end)
    reject(Conversations, :_unsafe_wake_bound_conversation, 1)

    assert {:ok, _} =
             PromptDelivery.accept(c.user.id, c.conv.id, "Review", [],
               idempotency_key: "low-level"
             )

    assert Repo.get(PromptWakeRequest, receipt.id) == nil
  end

  test "a failed wake-request insert rolls back the prompt and dispatch job", c do
    expect(PromptWake, :save!, fn parent, receipt ->
      assert parent.id == c.conv.id
      assert Repo.get!(Turn, receipt.turn_id)
      assert length(all_enqueued(worker: PromptDispatch)) == 1
      raise "wake persistence unavailable"
    end)

    assert_raise RuntimeError, "wake persistence unavailable", fn ->
      PromptDelivery.accept(c.user.id, c.conv.id, "Review", [])
    end

    assert Repo.aggregate(Turn, :count) == 0
    assert PromptDelivery.queued(c.user.id, c.conv.id) == nil
    assert all_enqueued(worker: PromptDispatch) == []
  end
end
