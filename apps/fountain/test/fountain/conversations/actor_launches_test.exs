defmodule Fountain.Conversations.ActorLaunchesTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{
    ActorClaim,
    ActorLaunch,
    ActorLaunches,
    ActorOwnership,
    PromptDelivery,
    PromptReceipt,
    Sandbox
  }

  alias Fountain.Workers.{ActorLaunchDispatch, ActorLaunchSweep}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    %{user: user, agent: agent}
  end

  defp create(c, opening \\ %{"prompt" => "Review this change"}) do
    {:ok, {sandbox, parent, launch}} =
      ActorLaunches.create(
        c.user.id,
        %{
          user_id: c.user.id,
          agent_id: c.agent.id,
          status: "pending",
          sprite_name: "launch-#{Ecto.UUID.generate()}"
        },
        %{user_id: c.user.id, agent_id: c.agent.id, runtime: c.agent.runtime, status: "pending"},
        opening
      )

    Map.merge(c, %{sandbox: sandbox, parent: parent, launch: launch})
  end

  defp deliver(c), do: ActorLaunches.deliver(c.user.id, c.parent.id, c.launch.id)

  defp claim(c, launch_id) do
    # Supplying the actor ID avoids starting a watchdog owned by this test process.
    state = %{
      user_id: c.user.id,
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id,
      actor_claim: Ecto.UUID.generate(),
      launch_id: launch_id
    }

    ActorOwnership.start(state, c.parent, c.sandbox, 30_000)
  end

  test "claim commits launch acknowledgment and actor identity together", c do
    c = create(c)
    assert {:ok, state, _, _} = claim(c, c.launch.id)
    launch = Repo.reload!(c.launch)
    assert launch.state == "acknowledged"
    assert launch.actor_claim_id == state.actor_claim
    assert Repo.get!(ActorClaim, state.actor_claim).launch_id == launch.id
    assert launch.deadline_at == c.launch.deadline_at
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = deliver(c)
    assert {:error, :actor_owned} = claim(c, c.launch.id)
    assert Repo.aggregate(ActorClaim, :count) == 1
  end

  test "a pending launch requires its exact launch ID", c do
    c = create(c)
    assert {:error, :launch_unavailable} = claim(c, nil)
    assert {:error, :launch_unavailable} = claim(c, Ecto.UUID.generate())
    assert Repo.reload!(c.launch).state == "requested"
    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  test "cancelled opening prevents both direct claim and dispatch", c do
    c = create(c)

    assert {:ok, _} =
             PromptDelivery.refuse(
               c.user.id,
               c.parent.id,
               c.launch.opening_receipt_id,
               "cancelled"
             )

    assert {:error, :opening_cancelled} = claim(c, c.launch.id)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = deliver(c)
    assert Repo.reload!(c.launch).failure_reason == "opening_cancelled"
    assert Repo.get!(PromptReceipt, c.launch.opening_receipt_id).failure_reason == "cancelled"
    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  test "foreign tenant and parent cannot dispatch an owned launch", c do
    c = create(c)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = ActorLaunches.deliver(Ecto.UUID.generate(), c.parent.id, c.launch.id)
    assert :ok = ActorLaunches.deliver(c.user.id, Ecto.UUID.generate(), c.launch.id)
    assert Repo.reload!(c.launch).state == "requested"
  end

  test "suspension after acceptance prevents claim and local start", c do
    c = create(c)

    c.user
    |> change(suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert {:error, :launch_admission_refused} = claim(c, c.launch.id)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = deliver(c)
    assert Repo.reload!(c.launch).failure_reason == "admission_refused"
    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  test "late start failure cannot fail an acknowledged actor or its prompt", c do
    c = create(c)

    expect(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      assert {:ok, _, _, _} = claim(c, c.launch.id)
      {:error, :max_children}
    end)

    assert :ok = deliver(c)
    assert Repo.reload!(c.launch).state == "acknowledged"
    assert Repo.reload!(c.parent).status == "pending"
    assert Repo.reload!(c.sandbox).status == "pending"
    assert Repo.get!(PromptReceipt, c.launch.opening_receipt_id).state == "queued"
  end

  test "runtime change refuses the launch without failing the changed parent", c do
    c = create(c)
    c.parent |> change(runtime: "codex") |> Repo.update!()
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = deliver(c)
    assert Repo.reload!(c.launch).failure_reason == "binding_changed"
    assert Repo.reload!(c.parent).status == "pending"
    assert Repo.reload!(c.sandbox).status == "pending"
  end

  test "creation without an opening prompt still has a durable launch", c do
    c = create(c, %{})
    assert c.launch.opening_receipt_id == nil
    assert Repo.aggregate(PromptReceipt, :count) == 0
    assert [job] = all_enqueued(worker: ActorLaunchDispatch)
    assert job.args["launch_id"] == c.launch.id
    assert {:ok, _, _, _} = claim(c, c.launch.id)
  end

  test "invalid parent rolls back its reservation and dispatch", c do
    assert {:error, _} =
             ActorLaunches.create(
               c.user.id,
               %{
                 user_id: c.user.id,
                 agent_id: c.agent.id,
                 sprite_name: "invalid-parent",
                 status: "pending"
               },
               %{
                 user_id: c.user.id,
                 agent_id: c.agent.id,
                 runtime: c.agent.runtime,
                 status: "not-a-status"
               },
               %{}
             )

    assert Repo.aggregate(Sandbox, :count) == 0
    assert Repo.aggregate(ActorLaunch, :count) == 0
    assert all_enqueued(worker: ActorLaunchDispatch) == []
  end

  for job_state <- ~w(available suspended discarded) do
    test "sweep handles a #{job_state} dispatch without duplicating incomplete work", c do
      c = create(c)
      [job] = all_enqueued(worker: ActorLaunchDispatch)
      job |> change(state: unquote(job_state)) |> Repo.update!()
      assert :ok = perform_job(ActorLaunchSweep, %{})

      active =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Fountain.Workers.ActorLaunchDispatch" and
                j.state in ["available", "suspended", "scheduled", "executing", "retryable"]
        )

      assert [dispatch] = active
      assert dispatch.args["launch_id"] == c.launch.id
      if unquote(job_state) != "discarded", do: assert(dispatch.id == job.id)
    end
  end

  test "sweep restores a lost dispatch but skips acknowledged launches", c do
    c = create(c)
    [job] = all_enqueued(worker: ActorLaunchDispatch)
    Repo.delete!(job)
    assert :ok = perform_job(ActorLaunchSweep, %{})
    assert [replacement] = all_enqueued(worker: ActorLaunchDispatch)
    assert replacement.id != job.id
    assert {:ok, _, _, _} = claim(c, c.launch.id)
    Repo.delete!(replacement)
    assert :ok = perform_job(ActorLaunchSweep, %{})
    assert all_enqueued(worker: ActorLaunchDispatch) == []
  end

  test "expired acceptance cannot be claimed or extended by dispatch", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "pending")
    parent = insert_conversation(user_id: c.user.id, sandbox: sandbox, agent_id: c.agent.id)

    launch =
      Repo.insert!(%ActorLaunch{
        user_id: c.user.id,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        runtime: parent.runtime,
        deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    c = Map.merge(c, %{sandbox: sandbox, parent: parent, launch: launch})
    assert {:error, :launch_expired} = claim(c, launch.id)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert :ok = deliver(c)
    assert Repo.reload!(launch).failure_reason == "launch_expired"
    assert Repo.reload!(launch).deadline_at == launch.deadline_at
    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  test "provider creation sees a committed claim; duplicate actors cannot create", c do
    handle = stub_happy_sprite()
    c = create(c, %{})
    owner = self()

    stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      refute Repo.in_transaction?()
      launch = Repo.reload!(c.launch)
      assert launch.state == "acknowledged"
      assert Repo.get!(ActorClaim, launch.actor_claim_id).launch_id == launch.id
      send(owner, {:provider_created, self()})
      {:ok, handle}
    end)

    stub(Conversations.Provisioning, :install_packages, fn _, _, _, _ ->
      send(owner, {:setup_waiting, self()})

      receive do
        :finish_setup -> :ok
      after
        5_000 -> raise "setup barrier not released"
      end
    end)

    args = [
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id,
      launch_id: c.launch.id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    {:ok, original} = GenServer.start(ConversationServer, args)
    on_exit(fn -> if Process.alive?(original), do: Process.exit(original, :kill) end)
    assert_receive {:provider_created, ^original}, 5_000
    assert_receive {:setup_waiting, ^original}, 5_000
    {:ok, duplicate} = GenServer.start(ConversationServer, args)
    monitor = Process.monitor(duplicate)
    assert_receive {:DOWN, ^monitor, :process, ^duplicate, :normal}, 5_000
    refute_received {:provider_created, _}
    send(original, :finish_setup)
    assert :sys.get_state(original, 5_000).sandbox_id == c.sandbox.id
    assert Repo.reload!(c.sandbox).status == "ready"
    GenServer.stop(original, :shutdown)

    # A normal ready-machine reattach retains provenance without another create.
    reject(Managoat.Sandbox.Sprites, :create, 2)
    stub(Conversations.Provisioning, :install_packages, fn _, _, _, _ -> :ok end)
    {:ok, successor} = GenServer.start(ConversationServer, Keyword.delete(args, :launch_id))
    on_exit(fn -> if Process.alive?(successor), do: GenServer.stop(successor) end)
    state = :sys.get_state(successor, 5_000)
    assert Repo.get!(ActorClaim, state.actor_claim).launch_id == c.launch.id
    assert Repo.reload!(c.launch).actor_claim_id != state.actor_claim
  end

  test "admission finishing after the deadline rolls back acknowledgment", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "pending")
    parent = insert_conversation(user_id: c.user.id, sandbox: sandbox, agent_id: c.agent.id)

    launch =
      Repo.insert!(%ActorLaunch{
        user_id: c.user.id,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        runtime: parent.runtime,
        deadline_at: DateTime.add(DateTime.utc_now(), 1, :second)
      })

    c = Map.merge(c, %{sandbox: sandbox, parent: parent, launch: launch})
    owner = self()

    expect(Fountain.Billing, :check_spend, fn _ ->
      send(owner, :entered_admission)
      remaining = max(DateTime.diff(launch.deadline_at, DateTime.utc_now(), :millisecond), 0)

      receive do
        :unexpected_release -> flunk("unexpected release")
      after
        remaining + 5 -> :ok
      end
    end)

    assert {:error, :launch_expired} = claim(c, launch.id)
    assert_received :entered_admission
    assert Repo.reload!(launch).state == "requested"
    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  test "another owned conversation can attach to an acknowledged ready machine", c do
    c = create(c, %{})
    assert {:ok, _, _, _} = claim(c, c.launch.id)
    {:ok, ready} = Conversations.update_sandbox(c.sandbox, %{status: "ready"})

    {:ok, attached} =
      Conversations.create_conversation(%{
        user_id: c.user.id,
        sandbox_id: ready.id,
        agent_id: c.agent.id,
        runtime: c.agent.runtime,
        status: "pending"
      })

    id = Ecto.UUID.generate()
    assert {:ok, actor} = ActorOwnership.claim(c.user.id, attached.id, ready.id, id)
    assert actor.launch_id == nil
    assert Repo.reload!(c.launch).conversation_id == c.parent.id
    assert Repo.reload!(c.launch).state == "acknowledged"
  end
end
