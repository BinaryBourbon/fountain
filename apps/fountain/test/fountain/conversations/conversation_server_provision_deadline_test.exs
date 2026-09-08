defmodule Fountain.Conversations.ConversationServerProvisionDeadlineTest do
  # #329: a ConversationServer stuck inside provisioning was invisible to
  # every reclamation mechanism — the reaper exempts rows whose server is
  # alive, and the server's own timers queue behind the stuck
  # handle_continue. The provision watchdog is an external process that
  # kills the server at an absolute deadline and applies the same
  # failed/failed transitions as the normal provision-failure path.
  use Fountain.ConversationServerCase

  setup do
    Application.put_env(:fountain, :provision_deadline_ms, 300)
    on_exit(fn -> Application.delete_env(:fountain, :provision_deadline_ms) end)
    :ok
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(100)
        wait_until(fun, tries - 1)
    end
  end

  test "a hung provision is killed at the deadline and its rows are failed" do
    stub_happy_sprite()

    # Stall provisioning indefinitely — the shape of a step that hangs
    # without raising (e.g. a stream that stops yielding chunks).
    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      Process.sleep(:infinity)
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    {:ok, pid} = GenServer.start(Fountain.Conversations.ConversationServer, args)
    ref = Process.monitor(pid)

    # The watchdog must kill the stuck server…
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    # …and then free the quota slot by failing the rows.
    wait_until(fn ->
      Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    end)

    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
  end

  test "the rows are terminal before the server is terminated (#394)" do
    # Pre-#394 the watchdog killed first and wrote the rows after. The server
    # is restart: :transient, so under Horde the kill triggered a restart that
    # re-read a still-pending row and provisioned a second billable sprite.
    # This pins the new contract: termination goes through the supervisor,
    # and by the time it happens the sandbox row is already failed — which is
    # what makes any restart stop at the terminal-status guard.
    stub_happy_sprite()

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      Process.sleep(:infinity)
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    test_pid = self()
    sandbox_id = conv.sandbox_id

    Mimic.stub(Horde.DynamicSupervisor, :terminate_child, fn _sup, pid ->
      status = Conversations._unsafe_get_sandbox!(sandbox_id).status
      send(test_pid, {:status_at_termination, status})
      Process.exit(pid, :kill)
      :ok
    end)

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    {:ok, pid} = GenServer.start(Fountain.Conversations.ConversationServer, args)
    ref = Process.monitor(pid)

    assert_receive {:status_at_termination, "failed"}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  test "a server restarted after the deadline provisions no second sprite (#394)" do
    handle = stub_happy_sprite()
    test_pid = self()

    # Count every sprite creation across all processes (global mode).
    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
      send(test_pid, :sprite_created)
      {:ok, handle}
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      Process.sleep(:infinity)
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    {:ok, pid} = GenServer.start(Fountain.Conversations.ConversationServer, args)
    ref = Process.monitor(pid)

    assert_receive :sprite_created, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    # What Horde's transient restart does after the watchdog fires: start a
    # fresh server on the same conversation, immediately. It must read the
    # terminal row and stop — never create a second sprite.
    {:ok, pid2} = GenServer.start(Fountain.Conversations.ConversationServer, args)
    ref2 = Process.monitor(pid2)

    assert_receive {:DOWN, ^ref2, :process, ^pid2, :normal}, 5_000
    refute_received :sprite_created
  end

  test "late provisioning cannot revive a sandbox retired while setup was running" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    stub_happy_sprite()
    owner = self()

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      send(owner, {:setup_waiting, self()})

      receive do
        :finish_setup -> :ok
      after
        5_000 -> raise "setup barrier was not released"
      end
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    ref = Process.monitor(pid)
    assert_receive {:setup_waiting, ^pid}, 5_000
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "terminated"})
    send(pid, :finish_setup)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status in ["terminated", "failed"]
    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
  end

  test "a late provisioning failure cannot fail or release a replacement worker" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    stub_happy_sprite()
    owner = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _, command, args, _ ->
      case {command, args} do
        {"bash", ["-lc", "controlled-setup"]} ->
          send(owner, {:old_setup_waiting, self()})

          receive do
            :fail_old_setup -> {:ok, "late setup output", 1}
          after
            5_000 -> raise "old setup barrier was not released"
          end

        _ ->
          {:ok, "", 0}
      end
    end)

    Mimic.stub(Fountain.Conversations.Egress, :release, fn _, id ->
      send(owner, {:conversation_sessions_released, id})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(owner, {:machine_destroyed, handle.name})
      :ok
    end)

    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "controlled-setup")
    agent = insert_agent(user_id: user.id, runtime: "gemini", environment_id: env.id)

    original =
      insert_sandbox(user_id: user.id, agent_id: agent.id, environment_id: agent.environment_id)

    conv = insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: original)

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: original.id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)
    assert_receive {:old_setup_waiting, ^pid}, 5_000
    original = Repo.reload!(original)

    replacement =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: original.agent_id,
        environment_id: original.environment_id,
        vault_id: original.vault_id,
        mode: original.mode
      )

    {:ok, moved} =
      Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "idle"})

    {:ok, receipt} =
      Fountain.Conversations.PromptDelivery.submit(user.id, moved.id, "replacement request", [])

    {:ok, turn} =
      Fountain.Conversations.PromptDelivery._unsafe_activate(moved.id, receipt.id, replacement.id)

    send(pid, :fail_old_setup)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    assert Repo.reload!(moved).status == "running"
    assert Repo.reload!(replacement).status == "ready"
    assert Repo.reload!(turn).status == "running"
    assert Repo.reload!(receipt).state == "claimed"
    refute_received {:conversation_sessions_released, _}
    refute_received {:machine_destroyed, _}

    refute Repo.exists?(
             from e in Fountain.Conversations.LogEvent,
               where:
                 e.conversation_id == ^conv.id and e.stage in ["setup", "provision"] and
                   e.state == "failed"
           )

    refute Repo.exists?(
             from e in Fountain.Conversations.LogEvent,
               where: e.conversation_id == ^conv.id and e.kind == "output" and e.stage == "setup"
           )
  end

  test "an unavailable failure decision retries without recreating or deleting the worker" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    handle = stub_happy_sprite()
    owner = self()
    {:ok, available} = Agent.start_link(fn -> false end)

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      send(owner, :sprite_created)
      {:ok, handle}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
      send(owner, :sprite_destroyed)
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _, _, _, _ ->
      {:error, :offline_setup_failure}
    end)

    Mimic.stub(Fountain.Workers.WebhookDelivery, :enqueue, fn endpoint, payload ->
      if payload["type"] == "conversation.provision.failed" and not Agent.get(available, & &1) do
        send(owner, :failure_enqueue_unavailable)
        {:error, :unavailable}
      else
        Mimic.call_original(Fountain.Workers.WebhookDelivery, :enqueue, [endpoint, payload])
      end
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, _} =
      Fountain.Webhooks.create_endpoint(user.id, %{"url" => "https://example.test/hook"})

    {:ok, receipt} =
      Fountain.Conversations.PromptDelivery.submit(user.id, conv.id, "Review", [])

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)
    assert_receive :sprite_created, 5_000
    assert_receive :failure_enqueue_unavailable, 5_000
    # Synchronize with the server after its failed transaction has rolled back.
    assert :sys.get_state(pid).sandbox_id == conv.sandbox_id
    assert Repo.reload!(conv).status == "pending"
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "starting"
    assert Repo.reload!(receipt).state == "queued"
    refute_received :sprite_created
    refute_received :sprite_destroyed

    Agent.update(available, fn _ -> true end)
    assert_receive :sprite_destroyed, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    assert Repo.reload!(conv).status == "failed"
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    assert Repo.reload!(receipt).failure_reason == "provisioning_failed"
    refute_received :sprite_created
    refute_received :sprite_destroyed

    assert Repo.aggregate(
             from(e in Fountain.Conversations.LogEvent,
               where:
                 e.conversation_id == ^conv.id and e.stage == "provision" and e.state == "failed"
             ),
             :count
           ) == 1
  end

  test "broker stage failure rolls back the token and retains the created machine for cleanup" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    handle = stub_happy_sprite()
    owner = self()
    Mimic.stub(Fountain.Conversations.Egress, :brokered?, fn _ -> true end)

    Mimic.stub(Fountain.Conversations.Provisioning, :check_broker_support, fn _, _, _, _ ->
      :ok
    end)

    Mimic.stub(Fountain.Broker, :prepare, fn id, brokered, bindings, opts ->
      Fountain.Broker.Native.prepare(id, brokered, bindings, opts)
    end)

    Mimic.stub(Fountain.Workers.WebhookDelivery, :enqueue, fn _, _ -> {:error, :unavailable} end)

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _, _ ->
      send(owner, :sprite_created)
      {:ok, handle}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn destroyed ->
      assert destroyed == handle
      send(owner, :sprite_destroyed)
      :ok
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, _} =
      Fountain.Webhooks.create_endpoint(user.id, %{
        "url" => "https://example.test/hook",
        "event_types" => ["conversation.broker.done"]
      })

    {:ok, receipt} =
      Fountain.Conversations.PromptDelivery.submit(user.id, conv.id, "Review", [])

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)
    assert_receive :sprite_created, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    assert_received :sprite_destroyed
    refute_received :sprite_created
    refute_received :sprite_destroyed
    assert Repo.reload!(conv).status == "failed"
    assert Repo.reload!(receipt).failure_reason == "provisioning_failed"
    assert Repo.aggregate(Fountain.Broker.Native.Session, :count) == 0
  end

  test "fresh wake waits for its binding before credentials and queues its prompt after commit" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    stub_happy_sprite()
    owner = self()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    old = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "terminated")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: old, status: "idle")

    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ ->
      send(owner, {:credentials_on, Repo.reload!(conv).sandbox_id})
      {:ok, <<0::256>>}
    end)

    Mimic.stub(Horde.DynamicSupervisor, :start_child, fn _sup, {ConversationServer, args} ->
      args = Keyword.put(args, :runtime_module, Managoat.Runtimes.Testing.FakeRuntime)
      {:ok, pid} = GenServer.start(ConversationServer, args)
      send(owner, {:child_before_binding, self(), pid})

      receive do
        :commit_binding -> {:ok, pid}
      after
        5_000 -> raise "binding handoff barrier timed out"
      end
    end)

    Mimic.stub(ConversationServer, :queue_prompt_receipt, fn pid, receipt_id ->
      send(owner, {:queued_after_binding, pid, receipt_id, Repo.reload!(conv).sandbox_id})
      :ok
    end)

    wake = Task.async(fn -> Conversations.wake_conversation(conv.id, "hello") end)
    assert_receive {:child_before_binding, caller, pid}, 5_000
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert Repo.reload!(conv).sandbox_id == old.id
    refute_receive {:credentials_on, _}
    refute_receive {:queued_after_binding, _, _, _}
    send(caller, :commit_binding)
    assert {:ok, woken} = Task.await(wake, 5_000)
    destination = woken.sandbox_id
    refute destination == old.id
    receipt = Fountain.Conversations.PromptDelivery.queued(user.id, conv.id)
    assert Repo.get!(Fountain.Conversations.Turn, receipt.turn_id).prompt == "hello"
    receipt_id = receipt.id
    assert_receive {:queued_after_binding, ^pid, ^receipt_id, ^destination}
    assert_receive {:credentials_on, ^destination}, 5_000
    state = :sys.get_state(pid, 5_000)
    assert state.sandbox_id == destination
    assert Conversations._unsafe_get_sandbox!(destination).status == "ready"
    assert Process.alive?(pid)
  end

  test "a stale child stops before credentials and leaves replacement execution running" do
    stub_happy_sprite()
    owner = self()

    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ ->
      send(owner, :credentials_loaded)
      {:ok, <<0::256>>}
    end)

    user = insert_verified_user()
    old = insert_sandbox(user_id: user.id)
    replacement = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: old, status: "idle")
    {:ok, conv} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
    turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    {:ok, execution} =
      Fountain.Conversations.ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: old.id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    refute_received :credentials_loaded
    assert Repo.reload!(turn).status == "running"
    assert Repo.reload!(execution).state == "active"
    assert Repo.reload!(conv).sandbox_id == replacement.id
    assert Repo.reload!(replacement).status == "ready"
    assert Repo.aggregate(Fountain.Conversations.LogEvent, :count) == 0
  end

  test "a moved conversation survives the old blocked actor's watchdog" do
    # A setup barrier proves the old actor actually entered provisioning.
    # Use an explicit watchdog deadline after the transfer so scheduler timing
    # cannot let the timeout race the test's setup.
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    stub_happy_sprite()
    owner = self()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    # Carry the original binding into the stub, as init does for the real watchdog.
    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _, _, _, _ ->
      send(owner, {:setup_waiting, self()})

      receive do
        :arm_watchdog ->
          Fountain.Conversations.ProvisionWatchdog.start(conv.id, conv.sandbox_id, 1)
      end

      Process.sleep(:infinity)
    end)

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    ref = Process.monitor(pid)
    assert_receive {:setup_waiting, ^pid}, 5_000
    replacement = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    current = Repo.reload!(conv)

    {:ok, current} =
      Conversations.update_conversation(current, %{sandbox_id: replacement.id, status: "idle"})

    Application.put_env(:fountain, :provision_deadline_ms, 1)
    send(pid, :arm_watchdog)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert Repo.reload!(current).status == "idle"
    assert Repo.reload!(current).sandbox_id == replacement.id
    assert Repo.reload!(replacement).status == "ready"

    refute Repo.exists?(
             from e in Fountain.Conversations.LogEvent,
               where:
                 e.conversation_id == ^conv.id and e.stage == "provision" and e.state == "failed"
           )
  end

  test "a provision that completes in time is left alone" do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, _ref, :alive} = start_server(conv)

    # Outlive the deadline, then confirm the watchdog did not fire.
    Process.sleep(600)
    assert Process.alive?(pid)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"

    GenServer.call(pid, :terminate_conv, 30_000)
  end

  test "bounded actor retains an uncertain deletion across restart and reaper cleanup" do
    Application.put_env(:fountain, :provision_deadline_ms, 30_000)
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    conv =
      conv
      |> Ecto.Changeset.change(execution_limits: %{"wall_time_seconds" => 60})
      |> Repo.update!()

    expected_id = Ecto.UUID.generate()
    owner = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :create_new, fn name, _ ->
      send(owner, :fresh_create)
      refute Repo.in_transaction?()
      {:ok, %Managoat.Sandbox.Handle{provider: :sprites, name: name, instance_id: expected_id}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ ->
      send(owner, :delete_attempt)
      {:error, :timeout}
    end)

    {pid, _, :alive} = start_server(conv)
    assert_receive :fresh_create
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.status == "ready"
    assert sandbox.provider_instance_id == expected_id
    assert GenServer.call(pid, :terminate_conv, 30_000) == :ok
    assert_receive :delete_attempt
    assert %{status: "terminated", terminated_at: nil} = Repo.reload!(sandbox)
    assert Fountain.Quotas.active_sandbox_count(user.id) == 1

    {:ok, restarted} =
      GenServer.start(ConversationServer,
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    ref = Process.monitor(restarted)
    assert_receive {:DOWN, ^ref, :process, ^restarted, :normal}, 5_000
    refute_received :fresh_create

    Mimic.stub(Managoat.Sandbox, :list_all_names, fn provider ->
      names = if provider == :sprites, do: [sandbox.sprite_name], else: []
      {:ok, MapSet.new(names)}
    end)

    assert :ok = Fountain.Workers.SandboxReaper.perform(%Oban.Job{})
    assert :ok = Fountain.Workers.SandboxReaper.perform(%Oban.Job{})
    assert Fountain.Quotas.active_sandbox_count(user.id) == 1
    refute_received :delete_attempt
  end
end
