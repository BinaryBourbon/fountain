defmodule Fountain.Conversations.FreshWakeLaunchTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{ActorLaunch, ActorLaunches, Sandbox, PromptDelivery}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    old = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "terminated")

    parent =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox: old,
        runtime: agent.runtime,
        status: "idle"
      )

    %{user: user, agent: agent, parent: parent, old: old}
  end

  test "fresh wake commits its replacement binding and launch before local startup", c do
    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      parent = Conversations.get_conversation(c.parent.id, c.user.id)
      assert parent.sandbox_id == args[:sandbox_id]
      assert Repo.get_by(ActorLaunch, conversation_id: parent.id, sandbox_id: args[:sandbox_id])
      {:ok, self()}
    end)

    assert {:ok, _} = Conversations.wake_conversation(c.parent.id)
  end

  test "creator death before fresh-wake startup retains a bound durable launch", c do
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      send(owner, {:before_launch, self(), args})
      receive do: (:continue -> {:ok, self()})
    end)

    caller = spawn(fn -> Conversations.wake_conversation(c.parent.id) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:before_launch, ^caller, args}, 5_000
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    replacement = Repo.get!(Sandbox, args[:sandbox_id])
    assert replacement.status == "pending"
    parent = Conversations.get_conversation(c.parent.id, c.user.id)
    assert parent.sandbox_id == replacement.id
    assert Repo.get_by(ActorLaunch, conversation_id: parent.id, sandbox_id: replacement.id)
  end

  defp attrs(c) do
    %{
      user_id: c.user.id,
      agent_id: c.agent.id,
      environment_id: c.parent.environment_id || c.agent.environment_id,
      vault_id: c.parent.vault_id,
      mode: c.old.mode,
      status: "pending",
      sprite_name: "local-replacement-#{Ecto.UUID.generate()}"
    }
  end

  test "a stale caller reuses the saved replacement at the account cap", c do
    c.user |> change(sandbox_limit_override: 1) |> Repo.update!()
    assert {:ok, {sandbox, parent, launch}} = ActorLaunches.replace(c.parent, c.old, attrs(c))

    assert {:ok, {reused, same_parent, same_launch}} =
             ActorLaunches.replace(c.parent, c.old, attrs(c))

    assert reused.id == sandbox.id
    assert same_parent.id == parent.id
    assert same_launch.id == launch.id
    assert Repo.aggregate(ActorLaunch, :count) == 1
    assert length(all_enqueued(worker: Fountain.Workers.ActorLaunchDispatch)) == 1
    assert Repo.aggregate(Sandbox, :count) == 2
  end

  test "replacement carries the queued opening receipt and cannot extend its deadline", c do
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.parent.id, "Wake for review", [])
    assert {:ok, {_, parent, launch}} = ActorLaunches.replace(c.parent, c.old, attrs(c))
    assert launch.opening_receipt_id == receipt.id
    assert DateTime.compare(launch.deadline_at, receipt.delivery_deadline_at) in [:lt, :eq]
    assert Repo.reload!(receipt).conversation_id == parent.id
    assert Repo.reload!(receipt).state == "queued"
  end

  test "invalid destination rolls back retirement of the old ready machine", c do
    ready = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "ready")
    {:ok, parent} = Conversations.update_conversation(c.parent, %{sandbox_id: ready.id})
    ready = Repo.reload!(ready)
    c = %{c | old: ready, parent: parent}

    assert {:error, %Ecto.Changeset{}} =
             ActorLaunches.replace(parent, ready, Map.put(attrs(c), :provider, "invalid"))

    assert Repo.reload!(ready).status == "ready"
    assert Repo.reload!(parent).sandbox_id == ready.id
    assert Repo.aggregate(ActorLaunch, :count) == 0
  end

  test "a failure saving the launch rolls back replacement binding and reservation", c do
    previous = Application.get_env(:fountain, :provision_deadline_ms)
    Application.put_env(:fountain, :provision_deadline_ms, 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :provision_deadline_ms, previous),
        else: Application.delete_env(:fountain, :provision_deadline_ms)
    end)

    assert_raise ArgumentError, "provision_deadline_ms must be positive", fn ->
      ActorLaunches.replace(c.parent, c.old, attrs(c))
    end

    assert Repo.reload!(c.parent).sandbox_id == c.old.id
    assert Repo.aggregate(Sandbox, :count) == 1
    assert Repo.aggregate(ActorLaunch, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.ActorLaunchDispatch) == []
  end

  test "changed source identity cannot be retired using an earlier provider observation", c do
    c.old |> change(provider_instance_id: "new-incarnation") |> Repo.update!()
    assert {:error, :ownership_changed} = ActorLaunches.replace(c.parent, c.old, attrs(c))
    assert Repo.reload!(c.parent).sandbox_id == c.old.id
    assert Repo.aggregate(Sandbox, :count) == 1
    assert Repo.aggregate(ActorLaunch, :count) == 0
  end

  test "a stale request cannot follow an unrelated replacement binding", c do
    other = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "ready")
    assert {:ok, _} = Conversations.update_conversation(c.parent, %{sandbox_id: other.id})
    assert {:error, :ownership_changed} = ActorLaunches.replace(c.parent, c.old, attrs(c))
    assert Repo.reload!(c.parent).sandbox_id == other.id
    assert Repo.aggregate(ActorLaunch, :count) == 0
  end

  test "caller death before Horde can be resumed from the saved launch job", c do
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      send(owner, {:before_launch, self(), args})
      receive do: (:continue -> {:ok, self()})
    end)

    caller = spawn(fn -> Conversations.wake_conversation(c.parent.id) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:before_launch, ^caller, args}, 5_000
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert [job] = all_enqueued(worker: Fountain.Workers.ActorLaunchDispatch)

    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, retry_args} ->
      assert retry_args == args
      {:ok, self()}
    end)

    assert {:snooze, 15} = perform_job(Fountain.Workers.ActorLaunchDispatch, job.args)
    assert Repo.aggregate(ActorLaunch, :count) == 1
    assert Repo.aggregate(Sandbox, :count) == 2
  end

  test "cancellation after wake invocation cannot become a prompt-free launch", c do
    stub(ConversationServer, :whereis, fn _ -> nil end)

    expect(Conversations, :_unsafe_wake_bound_conversation, fn parent, receipt_id ->
      receipt = PromptDelivery.queued(parent.user_id, parent.id)
      assert {:ok, _} = PromptDelivery.refuse(parent.user_id, parent.id, receipt.id, "cancelled")
      Mimic.call_original(Conversations, :_unsafe_wake_bound_conversation, [parent, receipt_id])
    end)

    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert {:ok, receipt} = PromptDelivery.accept(c.user.id, c.parent.id, "Wake for review", [])
    assert receipt.state == "refused"
    assert Repo.reload!(c.parent).sandbox_id == c.old.id
    assert Repo.aggregate(ActorLaunch, :count) == 0
  end

  test "a shared home and all idle holders move in the same transaction", c do
    home =
      insert_sandbox(
        user_id: c.user.id,
        agent_id: c.agent.id,
        mode: "persistent",
        status: "ready"
      )

    {:ok, parent} = Conversations.update_conversation(c.parent, %{sandbox_id: home.id})

    {:ok, peer} =
      Conversations.create_conversation(%{
        user_id: c.user.id,
        agent_id: c.agent.id,
        sandbox_id: home.id,
        runtime: c.agent.runtime,
        status: "idle"
      })

    home = Repo.reload!(home)
    c = %{c | parent: parent, old: home}
    assert {:ok, {replacement, moved, launch}} = ActorLaunches.replace(parent, home, attrs(c))
    assert replacement.mode == "persistent"
    assert Repo.reload!(home).status == "terminated"
    assert moved.sandbox_id == replacement.id
    assert Repo.reload!(peer).sandbox_id == replacement.id
    assert launch.source_sandbox_id == home.id
    assert Repo.aggregate(ActorLaunch, :count) == 1
    assert length(all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)) == 1
  end

  test "fresh-wake provider creation starts only after binding and claim commit", c do
    handle = stub_happy_sprite()
    owner = self()

    stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      refute Repo.in_transaction?()
      parent = Repo.reload!(c.parent)
      refute parent.sandbox_id == c.old.id
      launch = Repo.get_by!(ActorLaunch, sandbox_id: parent.sandbox_id)
      assert launch.source_sandbox_id == c.old.id
      assert launch.state == "acknowledged"
      send(owner, :created_after_commit)
      {:ok, handle}
    end)

    stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      {:ok, pid} =
        GenServer.start(
          ConversationServer,
          Keyword.put(args, :runtime_module, Managoat.Runtimes.Testing.FakeRuntime)
        )

      send(owner, {:actor_started, pid})
      {:ok, pid}
    end)

    assert {:ok, _} = Conversations.wake_conversation(c.parent.id)
    assert_receive {:actor_started, pid}, 5_000
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert_receive :created_after_commit, 5_000
    state = :sys.get_state(pid, 5_000)
    assert Repo.get!(Sandbox, state.sandbox_id).status == "ready"
  end

  test "a failed local start leaves an existing conversation retryable", c do
    expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:error, :max_children} end)
    assert {:error, :max_children} = Conversations.wake_conversation(c.parent.id)
    assert Repo.reload!(c.parent).status == "idle"
    assert Fountain.Quotas.active_sandbox_count(c.user.id) == 0
    expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, self()} end)
    assert {:ok, parent} = Conversations.wake_conversation(c.parent.id)
    assert parent.status == "pending"
    assert Fountain.Quotas.active_sandbox_count(c.user.id) == 1
  end

  test "an old-source actor claim cannot strand a refused unused replacement", c do
    source = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "ready")
    {:ok, parent} = Conversations.update_conversation(c.parent, %{sandbox_id: source.id})

    {:ok, old_claim} =
      Conversations.ActorOwnership.claim(c.user.id, parent.id, source.id, Ecto.UUID.generate())

    {:ok, _} = Conversations.update_sandbox(source, %{status: "terminated"})
    expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:error, :max_children} end)
    assert {:error, :max_children} = Conversations.wake_conversation(parent.id)
    launch = Repo.one!(ActorLaunch)
    assert launch.state == "refused"
    assert Repo.get!(Sandbox, launch.sandbox_id).status == "failed"
    assert Repo.reload!(parent).status == "idle"
    assert Repo.reload!(old_claim).state == "active"
    assert Fountain.Quotas.active_sandbox_count(c.user.id) == 0
  end
end
