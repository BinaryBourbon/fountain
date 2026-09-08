defmodule Fountain.Conversations.SandboxActivityTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{LogEvent, SandboxOperation, SandboxOperations, SandboxTransitions}

  setup do
    keys = [:sandbox_idle_timeout_minutes, :sandbox_max_lifetime_hours]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:fountain, &1)})
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 60)
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 0)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:fountain, key, old)
          :error -> Application.delete_env(:fountain, key)
        end
      end
    end)

    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "pending")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)

    {:ok, _} =
      SandboxOperations._unsafe_complete_create(
        creation.id,
        {:ok,
         %Managoat.Sandbox.Handle{
           provider: :sprites,
           name: sandbox.sprite_name,
           instance_id: Ecto.UUID.generate()
         }}
      )

    {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
    %{sandbox: age_sandbox_activity(sandbox), conv: Repo.reload!(conv), user: user}
  end

  test "a long turn that just finished keeps the machine active", c do
    turn = insert_turn(c.conv, status: "completed")
    old = c.sandbox.inserted_at

    turn
    |> Ecto.Changeset.change(
      inserted_at: old,
      started_at: old,
      ended_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update!()

    assert_refused(c.sandbox)
    assert {0, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
  end

  test "another holder's recent turn counts even after that holder ends", c do
    peer = insert_conversation(user_id: c.user.id, sandbox: c.sandbox, status: "terminated")
    age_sandbox_activity(c.sandbox)

    insert_turn(peer,
      status: "completed",
      ended_at: DateTime.truncate(DateTime.utc_now(), :second)
    )

    assert_refused(c.sandbox)
  end

  test "bookkeeping updates do not refresh activity", c do
    {:ok, _} = Conversations.update_conversation(c.conv, %{title: "bookkeeping"})

    {:ok, _} =
      Conversations.update_sandbox(c.sandbox, %{provider_meta: %{"note" => "bookkeeping"}})

    assert {:ok, _} = SandboxTransitions._unsafe_submit(c.sandbox, {:park, :idle})
  end

  test "attachment without a turn grants an idle grace period", c do
    assert {:ok, _} =
             Conversations.create_conversation(%{
               user_id: c.user.id,
               sandbox_id: c.sandbox.id,
               runtime: c.conv.runtime,
               status: "idle"
             })

    assert_refused(c.sandbox)
  end

  test "transfer of an old holder refreshes destination activity", c do
    source = insert_sandbox(user_id: c.user.id, status: "ready")
    peer = insert_conversation(user_id: c.user.id, sandbox: source, status: "idle")
    age_sandbox_activity(source)

    assert {:ok, _} =
             Conversations.update_conversation(Repo.reload!(peer), %{sandbox_id: c.sandbox.id})

    assert_refused(c.sandbox)
  end

  test "terminal holder revival is activity even without a binding change", c do
    {:ok, ended} = Conversations.update_conversation(c.conv, %{status: "terminated"})
    assert {:ok, _} = Conversations.update_conversation(ended, %{status: "idle"})
    assert_refused(c.sandbox)
  end

  test "disabled or extended policy refuses an earlier idle verdict", c do
    for minutes <- [nil, 0, 180] do
      Application.put_env(:fountain, :sandbox_idle_timeout_minutes, minutes)
      assert_refused(c.sandbox)
    end
  end

  test "a lifetime park requires the current continuous run to reach its bound", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    fresh = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, resumed} =
      Conversations.update_sandbox(c.sandbox, %{last_resumed_at: fresh, mode: "persistent"})

    assert_refused(resumed, :max_lifetime)
    assert_refused(resumed, :idle)

    {:ok, old_run} =
      Conversations.update_sandbox(resumed, %{last_resumed_at: c.sandbox.inserted_at})

    assert_refused(old_run, :idle)
    assert {:ok, _} = SandboxTransitions._unsafe_submit(old_run, {:park, :max_lifetime})
  end

  test "a park grant cannot carry a stale reason after policy changes", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    assert_refused(c.sandbox, :idle)
    {:ok, home} = Conversations.update_sandbox(c.sandbox, %{mode: "persistent"})
    assert {:ok, _} = SandboxTransitions._unsafe_submit(home, {:park, :max_lifetime})
  end

  test "resuming an owned parked machine does not require idle policy", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, {:park, :idle})
    {:ok, parked} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 0)
    assert {:ok, _} = SandboxTransitions._unsafe_submit(parked, "resume")
  end

  test "the actor deletes an expired ephemeral machine only after its grant commits", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)

    expect(Managoat.Sandbox.Sprites, :destroy_once, fn handle, _opts ->
      refute Repo.in_transaction?()
      assert handle.instance_id == c.sandbox.provider_instance_id
      assert Repo.reload!(c.sandbox).status == "terminated"

      assert Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy").state ==
               "submitted"

      assert Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot
      :ok
    end)

    state = %{
      conversation_id: c.conv.id,
      sandbox_id: c.sandbox.id,
      user_id: c.user.id,
      handle: nil
    }

    assert {:stop, :normal, _} =
             Conversations.Lifecycle.destroy_server(state, :max_lifetime, fn state, "reclaimed" ->
               state
             end)

    refute Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot
    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "disabled or extended lifetime preserves the actor and sends no deletion", c do
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    state = %{
      conversation_id: c.conv.id,
      sandbox_id: c.sandbox.id,
      user_id: c.user.id,
      handle: nil
    }

    for hours <- [0, nil, 3] do
      Application.put_env(:fountain, :sandbox_max_lifetime_hours, hours)

      assert {:noreply, ^state} =
               Conversations.Lifecycle.destroy_server(state, :max_lifetime, fn _, _ ->
                 flunk("connection dropped on refused bound")
               end)
    end

    assert Repo.reload!(c.sandbox).status == "ready"
    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy")
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "fresh wake and a running turn each refuse lifetime deletion", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)

    {:ok, resumed} =
      Conversations.update_sandbox(
        c.sandbox,
        %{last_resumed_at: DateTime.truncate(DateTime.utc_now(), :second)}
      )

    assert {:error, :lifecycle_bound_not_reached} =
             SandboxOperations._unsafe_destroy_at_bound(resumed, :max_lifetime)

    {:ok, old} = Conversations.update_sandbox(resumed, %{last_resumed_at: nil})
    insert_turn(c.conv, status: "running")

    assert {:error, :sandbox_mid_turn} =
             SandboxOperations._unsafe_destroy_at_bound(old, :max_lifetime)

    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy")
  end

  test "a current persistent home refuses a stale ephemeral deletion decision", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{mode: "persistent"})
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    assert {:error, :lifecycle_action_changed} =
             SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :max_lifetime)

    assert Repo.reload!(c.sandbox).status == "ready"
  end

  test "explicit owned deletion does not acquire an idle requirement", c do
    fresh = DateTime.truncate(DateTime.utc_now(), :second)
    {:ok, fresh_machine} = Conversations.update_sandbox(c.sandbox, %{last_resumed_at: fresh})
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 0)
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> :ok end)
    assert :ok = SandboxOperations._unsafe_destroy(fresh_machine, holder: c.conv.id)
    refute Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot
  end

  test "retired-holder recovery remains independent of disabled lifecycle policy", c do
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 0)
    {:ok, _} = Conversations.update_conversation(c.conv, %{status: "terminated"})
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> :ok end)
    assert :ok = SandboxOperations._unsafe_destroy(c.sandbox, recovery: true)
    refute Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot
  end

  test "a parked machine cannot receive a stale lifetime deletion grant", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "suspended"})

    assert {:error, :sandbox_not_ready} =
             SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :max_lifetime)

    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy")
  end

  test "the managed reaper parks a persistent home at its lifetime ceiling", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    {:ok, home} = Conversations.update_sandbox(c.sandbox, %{mode: "persistent"})
    age_sandbox_activity(home)
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)
    expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)
    assert {1, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
    assert Repo.reload!(home).status == "suspended"
    assert Repo.get_by!(SandboxOperation, sandbox_id: home.id, action: "create").holds_slot
    assert Jason.decode!(Repo.one!(LogEvent).data)["reason"] == "max_lifetime"
  end

  test "the managed reaper reclaims an ephemeral machine at its lifetime ceiling", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> :ok end)
    assert {0, 1} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
    assert Repo.reload!(c.sandbox).status == "terminated"
    refute Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot
  end

  test "a stale park mode cannot skip a current home's checkpoint", c do
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{mode: "persistent"})
    reject(Managoat.Sandbox, :suspend, 1)
    reject(Managoat.Sandbox, :create_checkpoint_once, 2)
    assert {:error, :lifecycle_action_changed} = SandboxTransitions._unsafe_park(c.sandbox, :idle)
    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "park")
  end

  test "an ephemeral lifetime ceiling cannot be downgraded to parking", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)

    assert {:error, :lifecycle_action_changed} =
             SandboxTransitions._unsafe_park(c.sandbox, :max_lifetime)

    assert {:error, :lifecycle_bound_not_reached} =
             SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :idle)

    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "park")
  end

  test "bound deletion refuses provider I/O inside an outer transaction", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    reject(Managoat.Sandbox.Sprites, :destroy_once, 2)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn ->
               SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :max_lifetime)
             end)

    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy")
  end

  test "an uncertain lifecycle deletion retains its slot and cannot replay", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> {:error, :timeout} end)

    assert {:error, :provider_operation_uncertain} =
             SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :max_lifetime)

    assert {:error, :provider_operation_fenced} =
             SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :max_lifetime)

    assert Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot

    assert Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy").state ==
             "uncertain"
  end

  test "a bound grant composes with rollback without a premature audit", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    reject(Fountain.Audit, :record, 1)

    assert {:error, :synthetic_rollback} =
             Repo.transaction(fn ->
               {:ok, _} =
                 SandboxOperations._unsafe_submit_destroy_at_bound(c.sandbox, :max_lifetime)

               assert Repo.reload!(c.sandbox).status == "terminated"
               Repo.rollback(:synthetic_rollback)
             end)

    assert Repo.reload!(c.sandbox).status == "ready"
    refute Repo.get_by(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy")
  end

  test "failed audit inserts cannot undo committed bound deletion", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)

    expect(Fountain.Audit, :record, 2, fn attrs ->
      refute Repo.in_transaction?()
      operation = Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy")
      assert operation.state == attrs.metadata["state"]

      assert {:error, :exception} =
               Mimic.call_original(Fountain.Audit, :record, [
                 Map.put(attrs, :action, String.duplicate("x", 256))
               ])
    end)

    expect(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ -> :ok end)
    assert :ok = SandboxOperations._unsafe_destroy_at_bound(c.sandbox, :max_lifetime)

    assert Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "destroy").state ==
             "confirmed"

    refute Repo.get_by!(SandboxOperation, sandbox_id: c.sandbox.id, action: "create").holds_slot
  end

  defp assert_refused(sandbox, reason \\ :idle) do
    reject(Managoat.Sandbox, :suspend, 1)
    reject(Managoat.Sandbox, :create_checkpoint_once, 2)

    assert {:error, :lifecycle_bound_not_reached} =
             SandboxTransitions._unsafe_park(sandbox, reason)

    assert Repo.reload!(sandbox).status == "ready"

    refute Repo.exists?(
             from o in SandboxOperation, where: o.sandbox_id == ^sandbox.id and o.action == "park"
           )

    assert Repo.aggregate(LogEvent, :count) == 0
  end
end
