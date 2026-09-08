defmodule Fountain.Conversations.ReadyWakeLaunchTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{
    ActorClaim,
    ActorLaunch,
    ActorLaunches,
    ActorOwnership,
    PromptDelivery,
    PromptReceipt,
    PromptWakeRequest,
    Sandbox,
    SandboxOperation
  }

  alias Fountain.Workers.{ActorLaunchDispatch, PromptDispatch}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    parent =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox: sandbox,
        runtime: agent.runtime,
        status: "idle"
      )

    stub(ConversationServer, :whereis, fn _ -> nil end)
    stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :running, raw: %{}}} end)
    %{user: user, parent: parent, sandbox: sandbox, agent: agent}
  end

  defp claim(c, launch_id) do
    state = %{
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id,
      user_id: c.user.id,
      actor_claim: Ecto.UUID.generate(),
      launch_id: launch_id
    }

    ActorOwnership.start(state, c.parent, c.sandbox, 30_000)
  end

  test "ready wake commits its request and job before Horde", c do
    expect(Horde.DynamicSupervisor, :start_child, fn _, {_, args} ->
      launch = Repo.get_by!(ActorLaunch, conversation_id: c.parent.id, state: "requested")
      assert launch.kind == "reconnect"
      assert args[:launch_id] == launch.id
      assert is_nil(args[:initial_prompt])
      assert [job] = all_enqueued(worker: ActorLaunchDispatch)
      assert job.args["launch_id"] == launch.id
      {:ok, self()}
    end)

    assert {:ok, receipt} =
             PromptDelivery.accept(c.user.id, c.parent.id, "Review this change", [])

    launch = Repo.get_by!(ActorLaunch, conversation_id: c.parent.id)
    assert launch.opening_receipt_id == receipt.id
    assert DateTime.compare(launch.deadline_at, receipt.delivery_deadline_at) != :gt
    assert Repo.aggregate(Sandbox, :count) == 1
    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  test "caller death before startup is recovered by the committed launch job", c do
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      send(owner, {:before_launch, self()})
      receive do: (:continue -> {:ok, self()})
    end)

    caller =
      spawn(fn -> PromptDelivery.accept(c.user.id, c.parent.id, "Review this change", []) end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:before_launch, ^caller}, 5_000
    receipt = PromptDelivery.queued(c.user.id, c.parent.id)
    assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"
    [prompt_job] = all_enqueued(worker: PromptDispatch)
    [launch_job] = all_enqueued(worker: ActorLaunchDispatch)
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

    # The old provider invocation remains fenced. Only local startup is retried.
    assert {:snooze, 15} = perform_job(PromptDispatch, prompt_job.args)

    expect(Horde.DynamicSupervisor, :start_child, fn _, {_, args} ->
      assert {:ok, _, _, _} = claim(c, args[:launch_id])
      send(owner, :durable_ready_start)
      {:ok, self()}
    end)

    assert :ok = perform_job(ActorLaunchDispatch, launch_job.args)
    assert_receive :durable_ready_start
    assert Repo.get!(ActorLaunch, launch_job.args["launch_id"]).state == "acknowledged"
    assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"

    # Retire the test's acknowledged actor normally, then submit a new prompt.
    # The old invocation remains recorded as interrupted but no longer strands
    # every future wake: its settled reconnect is durable handoff evidence.
    saved = Repo.get!(ActorLaunch, launch_job.args["launch_id"])

    ActorOwnership.finish(
      %{
        conversation_id: c.parent.id,
        sandbox_id: c.sandbox.id,
        user_id: c.user.id,
        actor_claim: saved.actor_claim_id
      },
      fn -> :ok end
    )

    assert {:ok, _} = PromptDelivery.refuse(c.user.id, c.parent.id, receipt.id, "cancelled")

    expect(Horde.DynamicSupervisor, :start_child, fn _, {_, args} ->
      refute args[:launch_id] == saved.id
      {:ok, self()}
    end)

    assert {:ok, _} = PromptDelivery.accept(c.user.id, c.parent.id, "A later review", [])
    assert Repo.aggregate(ActorLaunch, :count) == 2
  end

  test "concurrent callers converge on the pending reconnect without a new slot", c do
    assert {:ok, {_, first}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert {:ok, {_, second}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert first.id == second.id
    assert Repo.aggregate(Sandbox, :count) == 1
    assert length(all_enqueued(worker: ActorLaunchDispatch)) == 1
  end

  test "acknowledgment and claim share the exact reconnect identity", c do
    assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert {:error, :launch_unavailable} = claim(c, nil)
    assert {:error, :launch_unavailable} = claim(c, Ecto.UUID.generate())
    assert {:ok, state, _, _} = claim(c, launch.id)
    assert Repo.get!(ActorClaim, state.actor_claim).launch_id == launch.id
    assert Repo.reload!(launch).actor_claim_id == state.actor_claim
    assert {:error, :actor_owned} = claim(c, launch.id)
  end

  for status <- ~w(pending starting suspended terminated failed) do
    test "a reconnect cannot authorize startup on a #{status} machine", c do
      assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
      c.sandbox |> change(status: unquote(status)) |> Repo.update!()
      assert {:error, _} = claim(c, launch.id)
      reject(Horde.DynamicSupervisor, :start_child, 2)
      assert :ok = ActorLaunches.deliver(c.user.id, c.parent.id, launch.id)
      assert Repo.reload!(launch).state == "refused"
      assert Repo.reload!(c.sandbox).status == unquote(status)
      assert Repo.reload!(c.parent).status == "idle"
      assert Repo.aggregate(ActorClaim, :count) == 0
    end
  end

  test "startup refusal retains the ready machine and permits a new request", c do
    assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:error, :max_children} end)
    assert {:error, :max_children} = ActorLaunches.start(c.user.id, c.parent.id, launch.id)
    assert Repo.reload!(launch).failure_reason == "start_failed"
    assert Repo.reload!(c.parent).status == "idle"
    assert Repo.reload!(c.sandbox).status == "ready"
    assert {:ok, {_, next}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    refute next.id == launch.id
  end

  test "cancelled opening prevents reconnect without retiring its machine", c do
    stub(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, self()} end)

    assert {:ok, receipt} =
             PromptDelivery.accept(c.user.id, c.parent.id, "Review this change", [])

    launch = Repo.get_by!(ActorLaunch, opening_receipt_id: receipt.id)
    assert {:ok, _} = PromptDelivery.refuse(c.user.id, c.parent.id, receipt.id, "cancelled")
    assert {:error, :opening_cancelled} = claim(c, launch.id)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = ActorLaunches.deliver(c.user.id, c.parent.id, launch.id)
    assert Repo.reload!(launch).failure_reason == "opening_cancelled"
    assert Repo.get!(PromptReceipt, receipt.id).failure_reason == "cancelled"
    assert Repo.reload!(c.sandbox).status == "ready"
    assert {:error, :opening_cancelled} = ActorLaunches.reconnect(c.parent, c.sandbox, receipt.id)
  end

  test "the observed parent and provider identity are rechecked before acceptance", c do
    assert {:error, :ownership_changed} =
             ActorLaunches.reconnect(%{c.parent | user_id: Ecto.UUID.generate()}, c.sandbox)

    c.sandbox |> change(sprite_name: "changed-name") |> Repo.update!()
    assert {:error, :ownership_changed} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert Repo.aggregate(ActorLaunch, :count) == 0
  end

  test "new reconnects preserve creation history and fence stale child specifications", c do
    original =
      Repo.insert!(%ActorLaunch{
        user_id: c.user.id,
        conversation_id: c.parent.id,
        sandbox_id: c.sandbox.id,
        runtime: c.parent.runtime,
        state: "acknowledged",
        actor_claim_id: Ecto.UUID.generate(),
        acknowledged_at: DateTime.utc_now(),
        deadline_at: DateTime.add(DateTime.utc_now(), -60)
      })

    assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert {:error, :launch_unavailable} = claim(c, original.id)
    assert {:error, :launch_unavailable} = claim(c, nil)
    assert {:ok, _, _, _} = claim(c, launch.id)
    assert Repo.reload!(original) == original
    assert Repo.aggregate(ActorLaunch, :count) == 2
  end

  test "shared parents have distinct reconnect requests on the same machine", c do
    other =
      insert_conversation(
        user_id: c.user.id,
        agent_id: c.agent.id,
        sandbox: c.sandbox,
        runtime: c.agent.runtime,
        status: "idle"
      )

    assert {:ok, {_, first}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert {:ok, {_, second}} = ActorLaunches.reconnect(other, c.sandbox)
    refute first.id == second.id
    assert {:ok, _, _, _} = claim(c, first.id)
    assert {:ok, _, _, _} = claim(%{c | parent: other}, second.id)
    assert Repo.aggregate(Sandbox, :count) == 1
  end

  test "provider identity changes after acceptance prevent claim and dispatch", c do
    assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    c.sandbox |> change(provider_instance_id: "another-instance") |> Repo.update!()
    assert {:error, :ownership_changed} = claim(c, launch.id)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = ActorLaunches.deliver(c.user.id, c.parent.id, launch.id)
    assert Repo.reload!(launch).failure_reason == "binding_changed"
    assert Repo.reload!(c.sandbox).provider_instance_id == "another-instance"
    assert Repo.reload!(c.sandbox).status == "ready"
  end

  test "uncertain provider operations fence accepted reconnects", c do
    assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)

    operation =
      Repo.insert!(%SandboxOperation{
        sandbox_id: c.sandbox.id,
        user_id: c.user.id,
        provider: c.sandbox.provider,
        sandbox_name: c.sandbox.sprite_name,
        action: "create",
        state: "uncertain",
        holds_slot: true,
        submitted_at: DateTime.utc_now()
      })

    assert {:error, :provider_operation_fenced} = ActorLaunches.reconnect(c.parent, c.sandbox)
    assert {:error, :ownership_changed} = claim(c, launch.id)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = ActorLaunches.deliver(c.user.id, c.parent.id, launch.id)
    assert Repo.reload!(operation) == operation
    assert Repo.reload!(c.sandbox).status == "ready"
  end

  test "real reattach acknowledges the reconnect before provider setup and never creates", c do
    stub_happy_sprite()
    assert {:ok, {_, launch}} = ActorLaunches.reconnect(c.parent, c.sandbox)
    reject(Managoat.Sandbox.Sprites, :create, 2)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :get, fn _ ->
      refute Repo.in_transaction?()
      saved = Repo.reload!(launch)
      assert saved.state == "acknowledged"
      assert Repo.get!(ActorClaim, saved.actor_claim_id).launch_id == launch.id
      send(owner, :reattach_setup)
      {:ok, %{status: :running, raw: %{}}}
    end)

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: c.parent.id,
        sandbox_id: c.sandbox.id,
        launch_id: launch.id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert_receive :reattach_setup, 5_000
    assert :sys.get_state(pid, 5_000).sandbox_id == c.sandbox.id
    assert Repo.reload!(c.sandbox).status == "ready"
    assert Repo.aggregate(Sandbox, :count) == 1
    assert Repo.aggregate(SandboxOperation, :count) == 0
  end

  for transition <- [:suspended, :uncertain] do
    test "acknowledged reconnect cannot bypass #{transition} provider state" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

      parent =
        insert_conversation(
          user_id: user.id,
          agent_id: agent.id,
          sandbox: sandbox,
          runtime: agent.runtime,
          status: "idle"
        )

      {:ok, {_, launch}} = ActorLaunches.reconnect(parent, sandbox)

      state = %{
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        actor_claim: Ecto.UUID.generate(),
        launch_id: launch.id
      }

      {:ok, claimed, _, _} = ActorOwnership.start(state, parent, sandbox, 30_000)
      ActorOwnership.finish(claimed, fn -> :ok end)

      case unquote(transition) do
        :suspended ->
          sandbox |> change(status: "suspended") |> Repo.update!()

        :uncertain ->
          Repo.insert!(%SandboxOperation{
            sandbox_id: sandbox.id,
            user_id: user.id,
            provider: sandbox.provider,
            sandbox_name: sandbox.sprite_name,
            action: "create",
            state: "uncertain",
            holds_slot: true,
            submitted_at: DateTime.utc_now()
          })
      end

      assert {:error, _} =
               ActorOwnership.start(
                 %{state | actor_claim: Ecto.UUID.generate()},
                 parent,
                 sandbox,
                 30_000
               )
    end
  end

  test "an unresolved older launch refuses replacement without mutating its home", c do
    older =
      Repo.insert!(%ActorLaunch{
        user_id: c.user.id,
        conversation_id: c.parent.id,
        sandbox_id: c.sandbox.id,
        runtime: c.parent.runtime,
        deadline_at: DateTime.add(DateTime.utc_now(), 60)
      })

    assert {:error, :launch_unavailable} =
             ActorLaunches.replace(c.parent, c.sandbox, %{
               user_id: c.user.id,
               agent_id: c.agent.id,
               sprite_name: "another-machine",
               mode: c.sandbox.mode,
               status: "pending"
             })

    assert Repo.reload!(c.sandbox).status == "ready"
    assert Repo.reload!(c.parent).sandbox_id == c.sandbox.id
    assert Repo.reload!(older).state == "requested"
    assert Repo.aggregate(Sandbox, :count) == 1
    assert Repo.aggregate(ActorLaunch, :count) == 1
  end
end
