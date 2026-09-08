defmodule Fountain.Conversations.SandboxTransitionsTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Conversations, Quotas}

  alias Fountain.Conversations.{
    Lifecycle,
    LogEvent,
    SandboxOperation,
    SandboxOperations,
    SandboxTransitions
  }

  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "pending", mode: "ephemeral")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)

    handle = %Handle{
      provider: :sprites,
      name: sandbox.sprite_name,
      instance_id: "physical-instance"
    }

    {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})

    {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
    %{sandbox: sandbox, conv: conv, creation: creation, user: user}
  end

  test "park closes both admission doors and retains physical capacity", c do
    {:ok, operation} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    assert Repo.reload!(c.sandbox).status == "suspended"
    attrs = turn_attrs(c.conv)

    assert {:error, :sandbox_not_ready} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)

    assert {:error, :sandbox_not_ready} = Conversations._unsafe_create_autonomous_turn(attrs)

    assert {:ok, parked} =
             SandboxTransitions._unsafe_complete(operation.id, {:ok, :skipped}, :idle)

    assert parked.status == "suspended"
    assert Repo.reload!(c.creation).holds_slot
    assert Quotas.fleet_count() == 1
    assert Repo.aggregate(LogEvent, :count) == 1

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_complete(operation.id, {:ok, :skipped}, :idle)

    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "a winning user or autonomous turn refuses park before any provider call", c do
    {:ok, turn} =
      Conversations._unsafe_create_turn_on_sandbox(turn_attrs(c.conv), c.sandbox.id, :unbounded)

    reject(Managoat.Sandbox, :suspend, 1)
    assert {:error, :sandbox_mid_turn} = SandboxTransitions._unsafe_park(c.sandbox, :idle)
    turn |> Ecto.Changeset.change(status: "completed") |> Repo.update!()

    {:ok, _} =
      Conversations._unsafe_create_autonomous_turn(%{turn_attrs(c.conv) | turn_number: 2})

    assert {:error, :sandbox_mid_turn} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    assert Repo.reload!(c.sandbox).status == "ready"
  end

  test "a pending transition still fences admission after an unrelated stale ready write", c do
    {:ok, _} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    c.sandbox |> Repo.reload!() |> Ecto.Changeset.change(status: "ready") |> Repo.update!()

    assert {:error, :provider_operation_fenced} =
             Conversations._unsafe_create_autonomous_turn(turn_attrs(c.conv))

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_submit(Repo.reload!(c.sandbox), "park")
  end

  test "resume confirms the retained instance outside locks and readmits work", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    {:ok, parked} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)

    expect(Managoat.Sandbox, :get, fn handle ->
      refute Repo.in_transaction?()
      assert handle.instance_id == "physical-instance"
      assert SandboxTransitions._unsafe_pending?(c.sandbox.id)
      {:ok, %{raw: %{"id" => "physical-instance"}}}
    end)

    assert {:ok, ready} = SandboxTransitions._unsafe_resume(parked)
    assert ready.status == "ready"
    refute SandboxTransitions._unsafe_park_current?(ready.id, park.id)

    assert {:ok, _} =
             Conversations._unsafe_create_turn_on_sandbox(
               turn_attrs(c.conv),
               ready.id,
               :unbounded
             )
  end

  test "presence for another incarnation cannot reopen a parked machine", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    {:ok, parked} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
    {:ok, resume} = SandboxTransitions._unsafe_submit(parked, "resume")

    assert {:error, :provider_operation_uncertain} =
             SandboxTransitions._unsafe_complete(
               resume.id,
               {:ok, %{raw: %{"id" => "replacement"}}},
               :wake
             )

    assert Repo.reload!(resume).state == "uncertain"
    assert Repo.reload!(c.sandbox).status == "suspended"
    assert Quotas.fleet_count() == 1
  end

  test "uncertainty and restart do not grant another park or resume", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")

    assert {:error, :provider_operation_uncertain} =
             SandboxTransitions._unsafe_complete(park.id, {:error, :timeout}, :idle)

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_submit(Repo.reload!(c.sandbox), "resume")

    assert Repo.aggregate(LogEvent, :count) == 0
    assert Repo.reload!(park).state == "uncertain"
    assert Repo.reload!(c.creation).holds_slot

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_submit_destroy(Repo.reload!(c.sandbox))
  end

  test "late completion cannot revive a retired sandbox or publish success", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "terminated"})

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)

    assert Repo.reload!(c.sandbox).status == "terminated"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "ownership change and account deletion refuse late completion", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    c.sandbox |> Ecto.Changeset.change(user_id: insert_verified_user().id) |> Repo.update!()

    assert {:error, :ownership_changed} =
             SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)

    c.sandbox |> Repo.reload!() |> Ecto.Changeset.change(user_id: c.user.id) |> Repo.update!()
    Repo.delete!(c.user)

    assert {:error, :ownership_changed} =
             SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)

    assert Repo.reload!(c.creation).holds_slot
  end

  test "park after parent deletion records no orphan transcript", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    Repo.delete!(c.conv)
    assert {:ok, _} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "managed actor action selection makes no provider request", c do
    reject(Managoat.Sandbox, :suspend, 1)
    assert Lifecycle.idle_machine_action(c.conv.id, nil) == :park
    assert Lifecycle.max_lifetime_action(c.sandbox.id, nil) == :destroy
  end

  test "actor parks through the durable grant before dropping its connection", c do
    expect(Managoat.Sandbox, :suspend, fn handle ->
      refute Repo.in_transaction?()
      assert handle.instance_id == "physical-instance"
      assert SandboxTransitions._unsafe_pending?(c.sandbox.id)
      :ok
    end)

    state = %{conversation_id: c.conv.id, sandbox_id: c.sandbox.id, handle: :held}

    assert {:stop, :normal, %{handle: nil}} =
             Lifecycle.park_server(state, :idle, fn state, "suspended" ->
               refute SandboxTransitions._unsafe_pending?(c.sandbox.id)
               state
             end)
  end

  test "refused actor park keeps its existing connection", c do
    insert_turn(c.conv, status: "running")
    state = %{conversation_id: c.conv.id, sandbox_id: c.sandbox.id, handle: :held}

    assert {:noreply, ^state} =
             Lifecycle.park_server(state, :idle, fn _, _ -> flunk("connection was dropped") end)
  end

  test "reset refuses an outstanding transition", c do
    sandbox = c.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()
    {:ok, _} = SandboxTransitions._unsafe_submit(sandbox, "park")
    assert {:error, :provider_operation_fenced} = Conversations.reset_sandbox(sandbox)
    assert Repo.reload!(sandbox).status == "suspended"
  end

  test "a home checkpoint is made once and published only after transition confirmation", c do
    sandbox = c.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()

    expect(Managoat.Sandbox, :create_checkpoint, fn handle, _ ->
      refute Repo.in_transaction?()
      assert handle.instance_id == "physical-instance"
      assert Repo.reload!(sandbox).provider_meta["checkpoint_id"] == nil
      {:ok, "checkpoint-one"}
    end)

    expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)
    expect(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{} end)

    expect(Sprites, :get_checkpoint, fn sprite, "checkpoint-one" ->
      assert sprite.name == sandbox.sprite_name
      operation = Repo.one!(from o in SandboxOperation, where: o.action == "park")
      {:ok, %Sprites.Checkpoint{id: "checkpoint-one", comment: "managed park #{operation.id}"}}
    end)

    assert {:ok, parked} = SandboxTransitions._unsafe_park(sandbox, :idle)
    assert parked.provider_meta["checkpoint_id"] == "checkpoint-one"
    assert Repo.aggregate(from(o in SandboxOperation, where: o.action == "park"), :count) == 1
  end

  test "provider timeout retains the transition without a second request", c do
    expect(Managoat.Sandbox, :suspend, fn _ ->
      Process.sleep(1_000)
      :ok
    end)

    assert {:error, :provider_operation_uncertain} =
             SandboxTransitions._unsafe_park(c.sandbox, :idle, 20)

    assert Repo.one!(from o in SandboxOperation, where: o.action == "park").state == "uncertain"

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_resume(Repo.reload!(c.sandbox))

    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "a ready reuse proves identity and refuses a concurrent retirement", c do
    expect(Managoat.Sandbox, :get, fn _ ->
      refute Repo.in_transaction?()
      {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "terminated"})
      {:ok, %{raw: %{"id" => "physical-instance"}}}
    end)

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_verify_ready(c.sandbox)
  end

  test "ready presence for another provider instance cannot authorize reuse", c do
    expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{raw: %{"id" => "other"}}} end)
    assert {:error, :sprite_probe_failed} = SandboxTransitions._unsafe_verify_ready(c.sandbox)
  end

  test "a delayed park notification cannot stop a resumed actor", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")
    {:ok, parked} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
    {:ok, resume} = SandboxTransitions._unsafe_submit(parked, "resume")

    {:ok, _} =
      SandboxTransitions._unsafe_complete(
        resume.id,
        {:ok, %{raw: %{"id" => "physical-instance"}}},
        :wake
      )

    state = %{sandbox_id: c.sandbox.id, handle: :successor}

    assert {:noreply, ^state} =
             Conversations.ConversationServer.handle_cast(
               {:managed_park, c.sandbox.id, park.id},
               state
             )
  end

  test "a pending park refuses actor destruction without bookkeeping or connection loss", c do
    {:ok, _} = SandboxTransitions._unsafe_submit(c.sandbox, "park")

    state = %{
      conversation_id: c.conv.id,
      sandbox_id: c.sandbox.id,
      user_id: c.user.id,
      handle: :held
    }

    assert {:noreply, ^state} =
             Lifecycle.destroy_server(state, :max_lifetime, fn _, _ ->
               flunk("connection dropped on refusal")
             end)

    assert Repo.reload!(c.sandbox).status == "suspended"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "actual reaper parks a managed abandoned sandbox through the journal", c do
    old = DateTime.add(DateTime.utc_now(), -7_200, :second) |> DateTime.truncate(:second)
    c.sandbox |> Ecto.Changeset.change(inserted_at: old, updated_at: old) |> Repo.update!()

    expect(Managoat.Sandbox, :suspend, fn _ ->
      refute Repo.in_transaction?()
      assert SandboxTransitions._unsafe_pending?(c.sandbox.id)
      :ok
    end)

    assert {1, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
    assert Repo.reload!(c.sandbox).status == "suspended"
    assert Repo.one!(from o in SandboxOperation, where: o.action == "park").state == "confirmed"
  end

  test "an outer transaction cannot turn the provider phase into uncommitted I/O", c do
    reject(Managoat.Sandbox, :suspend, 1)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn ->
               SandboxTransitions._unsafe_park(c.sandbox, :idle)
             end)

    assert Repo.reload!(c.sandbox).status == "ready"
    refute SandboxTransitions._unsafe_pending?(c.sandbox.id)
  end

  test "park events and notifications commit together without a premature broadcast", c do
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, "park")

    assert {:error, :synthetic_rollback} =
             Repo.transaction(fn ->
               {:ok, _} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
               refute_receive {:log_event, _}, 20
               Repo.rollback(:synthetic_rollback)
             end)

    assert Repo.aggregate(LogEvent, :count) == 0
    assert Repo.reload!(park).state == "submitted"
    assert {:ok, _} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
    event = Repo.one!(LogEvent)

    job =
      Repo.one!(
        from j in Oban.Job, where: j.worker == "Fountain.Workers.TurnDeadlineNotification"
      )

    assert job.args["event_id"] == event.id
    assert :ok = Fountain.Workers.TurnDeadlineNotification.perform(job)
    assert_receive {:log_event, ^event}
  end

  test "the provider task timeout survives loss of its caller", c do
    owner = self()

    expect(Managoat.Sandbox, :suspend, fn _ ->
      send(owner, {:provider_waiting, self()})

      receive do
        :never -> :ok
      end
    end)

    caller =
      Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn ->
        SandboxTransitions._unsafe_park(c.sandbox, :idle, 100)
      end)

    assert_receive {:provider_waiting, provider}, 1_000
    monitor = Process.monitor(provider)
    Process.exit(caller.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^provider, :killed}, 1_000
    assert {:exit, :killed} = Task.yield(caller, 1_000)
    operation = Repo.one!(from o in SandboxOperation, where: o.action == "park")
    assert operation.state == "submitted"
    assert SandboxOperations._unsafe_recover_submissions(DateTime.add(DateTime.utc_now(), 1)) == 1
    assert Repo.reload!(operation).state == "uncertain"
    assert Repo.reload!(c.creation).holds_slot
  end

  test "the adapter's older checkpoint fallback cannot become this park's checkpoint", c do
    sandbox = c.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()

    expect(Managoat.Sandbox, :create_checkpoint, fn _handle, opts ->
      operation = Repo.one!(from o in SandboxOperation, where: o.action == "park")
      assert opts[:comment] == "managed park #{operation.id}"
      {:ok, "older-checkpoint"}
    end)

    expect(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{} end)

    expect(Sprites, :get_checkpoint, fn _, "older-checkpoint" ->
      {:ok, %Sprites.Checkpoint{id: "older-checkpoint", comment: "another attempt"}}
    end)

    expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)
    assert {:ok, parked} = SandboxTransitions._unsafe_park(sandbox, :idle)
    refute parked.provider_meta["checkpoint_id"]
  end

  defp turn_attrs(conv),
    do: %{
      conversation_id: conv.id,
      turn_number: 1,
      prompt: "work",
      status: "running",
      started_at: DateTime.utc_now()
    }
end
