defmodule Fountain.Conversations.ActorStartupsTest do
  use Fountain.ConversationServerCase

  alias Fountain.Broker.Native
  alias Fountain.Broker.Native.Sessions

  alias Fountain.Conversations.{
    ActorStartup,
    ActorStartups,
    ActorOwnership,
    ActorLaunches,
    LogEvent,
    PromptDelivery,
    ProvisionContext,
    ProvisionWatchdog,
    SandboxOperation
  }

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

    %{user: user, agent: agent, sandbox: sandbox, parent: parent}
  end

  defp startup(c, seconds \\ -1) do
    id = Ecto.UUID.generate()
    {:ok, claim} = ActorOwnership.claim(c.user.id, c.parent.id, c.sandbox.id, id)

    startup =
      Repo.insert!(%ActorStartup{
        id: id,
        user_id: c.user.id,
        conversation_id: c.parent.id,
        sandbox_id: c.sandbox.id,
        deadline_at: DateTime.add(DateTime.utc_now(), seconds)
      })

    state = %{
      actor_claim: id,
      user_id: c.user.id,
      conversation_id: c.parent.id,
      sandbox_id: c.sandbox.id
    }

    Map.merge(c, %{claim: claim, startup: startup, state: state})
  end

  test "expiry revokes only this conversation and retains its machine, claims and cotenant", c do
    c = startup(c)
    {:ok, {key, _}} = Fountain.Accounts.create_api_key(c.user.id, "startup callback")
    c.parent |> change(callback_api_key_id: key.id) |> Repo.update!()
    {:ok, own_session} = Native.prepare(c.parent.id, %{}, %{}, user_id: c.user.id)

    other =
      insert_conversation(
        user_id: c.user.id,
        agent_id: c.agent.id,
        sandbox: c.sandbox,
        runtime: c.agent.runtime,
        status: "running"
      )

    {:ok, other_session} = Native.prepare(other.id, %{}, %{}, user_id: c.user.id)
    turn = insert_turn(other, status: "running")
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.parent.id, "Review", [])

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

    assert {:ok, :expired} =
             ProvisionWatchdog._unsafe_expire(c.parent.id, c.sandbox.id, c.claim.id)

    assert Repo.reload!(c.startup).state == "expired"
    assert Repo.reload!(c.claim).state == "active"
    assert Repo.reload!(c.sandbox).status == "ready"
    assert Repo.reload!(c.parent).status == "idle"
    assert Repo.reload!(operation) == operation
    assert Repo.reload!(turn).status == "running"
    assert Repo.reload!(other).status == "running"
    assert Repo.reload!(key).revoked_at
    assert :error = Sessions.lookup(own_session.token)
    assert {:ok, _} = Sessions.lookup(other_session.token)
    assert Repo.reload!(receipt).failure_reason == "provisioning_failed"

    assert {:error, :actor_owned} =
             ActorOwnership.claim(c.user.id, c.parent.id, c.sandbox.id, Ecto.UUID.generate())

    assert {:error, :startup_unresolved} = ActorLaunches.reconnect(c.parent, c.sandbox)
  end

  test "expired ownership fences callbacks and cannot be released by normal teardown", c do
    c = startup(c)
    assert {:ok, :expired} = ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id)
    refute ActorOwnership.current?(c.state)
    context = ProvisionContext.new(c.parent, c.sandbox, c.claim.id)
    assert nil == ProvisionContext.output(context, "setup", "late output")
    assert nil == ProvisionContext.stage(context, "reattach", "done")
    assert {:error, :startup_expired} = ActorStartups.complete(c.state)

    assert {:stop, :normal, _} =
             ActorStartups.after_return(c.state, fn -> flunk("late callback ran") end)

    assert :ok = ActorOwnership.finish(c.state, fn -> flunk("expired teardown ran") end)
    assert Repo.reload!(c.claim).state == "active"
    assert {:error, :actor_retired} = ActorOwnership.start(c.state, c.parent, c.sandbox, 30_000)
    assert Repo.aggregate(LogEvent, :count) == 1
    assert {:ok, :expired} = ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id)
    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "completion after the accepted deadline commits expiry rather than late success", c do
    c = startup(c)
    assert {:error, :startup_expired} = ActorStartups.complete(c.state)
    assert Repo.reload!(c.startup).state == "expired"
    refute ActorOwnership.current?(c.state)
  end

  for outcome <- [:complete, :returned] do
    test "#{outcome} before expiry settles the watchdog and permits normal teardown", c do
      c = startup(c, 60)
      assert :ok = apply(ActorStartups, unquote(outcome), [c.state])
      assert {:ok, :settled} = ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id)
      assert ActorOwnership.current?(c.state)
      assert :ok = ActorOwnership.finish(c.state, fn -> :ok end)
      assert Repo.reload!(c.claim).state == "stopped"
      assert Repo.reload!(c.sandbox).status == "ready"
      assert Repo.aggregate(LogEvent, :count) == 0
    end
  end

  test "teardown during unfinished startup retains ownership for reconciliation", c do
    c = startup(c, 60)
    assert :ok = ActorOwnership.finish(c.state, fn -> :ok end)
    assert Repo.reload!(c.claim).state == "active"
    assert Repo.reload!(c.startup).state == "starting"

    assert {:error, :actor_owned} =
             ActorOwnership.claim(c.user.id, c.parent.id, c.sandbox.id, Ecto.UUID.generate())
  end

  test "expiry before its deadline has no side effects", c do
    c = startup(c, 60)

    assert {:error, :deadline_not_reached} =
             ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id)

    assert Repo.reload!(c.startup).state == "starting"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "a foreign outcome cannot settle this incarnation", c do
    c = startup(c, 60)

    assert_raise ArgumentError, fn ->
      ActorStartups.complete(%{c.state | user_id: Ecto.UUID.generate()})
    end

    assert {:ok, :stale} = ActorStartups.expire(Ecto.UUID.generate(), c.sandbox.id, c.claim.id)
    assert Repo.reload!(c.startup).state == "starting"
  end

  test "failed event enqueue rolls back expiry and access revocation", c do
    c = startup(c)
    {:ok, session} = Native.prepare(c.parent.id, %{}, %{}, user_id: c.user.id)

    {:ok, _} =
      Fountain.Webhooks.create_endpoint(c.user.id, %{
        "url" => "https://example.test/hook",
        "event_types" => ["conversation.reattach.failed"]
      })

    expect(Fountain.Workers.WebhookDelivery, :enqueue, fn _, _ -> {:error, :unavailable} end)

    assert {:error, :decision_unavailable} =
             ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id)

    assert Repo.reload!(c.startup).state == "starting"
    assert {:ok, _} = Sessions.lookup(session.token)
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "an acknowledged reconnect blocked in provider access reaches its accepted deadline" do
    previous = Application.fetch_env(:fountain, :provision_deadline_ms)
    Application.put_env(:fountain, :provision_deadline_ms, 300)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :provision_deadline_ms, value)
        :error -> Application.delete_env(:fountain, :provision_deadline_ms)
      end
    end)

    user = insert_verified_user(email: "reattach-deadline-#{Ecto.UUID.generate()}@example.test")
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
    owner = self()

    stub(Managoat.Sandbox.Sprites, :get, fn _ ->
      send(owner, :blocked_provider_get)
      Process.sleep(:infinity)
    end)

    stub(Horde.DynamicSupervisor, :terminate_child, fn _, pid ->
      Process.exit(pid, :kill)
      :ok
    end)

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        launch_id: launch.id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)
    assert_receive :blocked_provider_get, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
  end

  test "expired startup prevents reset, replacement, cleanup and abandoned-machine reaping", c do
    sandbox = c.sandbox |> change(mode: "persistent") |> Repo.update!()
    c = startup(%{c | sandbox: sandbox})
    assert {:ok, :expired} = ActorStartups.expire(c.parent.id, c.sandbox.id, c.claim.id)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    reject(Managoat.Sandbox.Sprites, :suspend, 1)
    assert {:error, :sandbox_mid_turn} = Conversations.reset_sandbox(c.sandbox)

    assert {:error, :startup_unresolved} =
             ActorLaunches.replace(c.parent, c.sandbox, %{
               user_id: c.user.id,
               agent_id: c.agent.id,
               mode: "persistent",
               sprite_name: "unused-replacement",
               status: "pending"
             })

    handle = Managoat.Sandbox.build_handle(:sprites, c.sandbox.sprite_name)

    assert {:error, :startup_unresolved} =
             Conversations.SandboxOperations._unsafe_destroy_or_legacy(c.sandbox, handle)

    previous = Application.fetch_env(:fountain, :sandbox_max_lifetime_hours)
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :sandbox_max_lifetime_hours, value)
        :error -> Application.delete_env(:fountain, :sandbox_max_lifetime_hours)
      end
    end)

    old = DateTime.utc_now() |> DateTime.add(-86_400) |> DateTime.truncate(:second)

    from(s in Conversations.Sandbox, where: s.id == ^c.sandbox.id)
    |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    stub(ConversationServer, :whereis, fn _ -> nil end)
    assert {0, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
    assert Repo.reload!(c.sandbox).status == "ready"
  end
end
