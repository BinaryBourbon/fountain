defmodule Fountain.Conversations.SandboxHoldersTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations

  alias Fountain.Conversations.{
    ExecutionGuard,
    Lifecycle,
    LogEvent,
    SandboxHolders,
    SandboxOperations,
    SandboxTransitions
  }

  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {source, parent, creation} = managed(user, agent)
    %{user: user, agent: agent, source: source, parent: parent, creation: creation}
  end

  test "a confirmed ready or suspended machine can accept another owned holder", c do
    assert {:ok, _} = Conversations.create_conversation(attrs(c.source, c.agent))
    source = age_sandbox_activity(c.source)
    {:ok, parked} = SandboxTransitions._unsafe_park(source, :idle)
    assert {:ok, holder} = Conversations.create_conversation(attrs(parked, c.agent))
    assert holder.sandbox_id == c.source.id
    assert Repo.reload!(c.creation).holds_slot
  end

  test "creation rechecks tenant and disk identity", c do
    foreign = insert_verified_user()
    foreign_agent = insert_agent(user_id: foreign.id)

    assert {:error, :ownership_changed} =
             Conversations.create_conversation(%{attrs(c.source, c.agent) | user_id: foreign.id})

    assert {:error, :ownership_changed} =
             Conversations.create_conversation(%{
               attrs(c.source, c.agent)
               | agent_id: foreign_agent.id
             })

    other_agent = insert_agent(user_id: c.user.id)

    assert {:error, :sandbox_identity_mismatch} =
             Conversations.create_conversation(%{
               attrs(c.source, c.agent)
               | agent_id: other_agent.id
             })

    assert {:error, :sandbox_runtime_mismatch} =
             Conversations.create_conversation(%{attrs(c.source, c.agent) | runtime: "codex"})
  end

  test "pending park rejects inserts and transfers before changing ownership", c do
    {:ok, operation} = SandboxTransitions._unsafe_submit(c.source, {:park, :idle})
    {other, other_parent, _} = managed(c.user, c.agent)

    assert {:error, :provider_operation_fenced} =
             Conversations.create_conversation(attrs(c.source, c.agent))

    assert {:error, :provider_operation_fenced} =
             Conversations.update_conversation(other_parent, %{sandbox_id: c.source.id})

    assert Repo.reload!(other_parent).sandbox_id == other.id
    assert Repo.reload!(operation).state == "submitted"
  end

  test "uncertain source operations cannot be escaped by moving a holder", c do
    {:ok, operation} = SandboxTransitions._unsafe_submit(c.source, {:park, :idle})
    {:ok, _} = SandboxOperations._unsafe_mark_uncertain(operation.id)
    {other, _, _} = managed(c.user, c.agent)

    assert {:error, :provider_operation_fenced} =
             Conversations.update_conversation(c.parent, %{sandbox_id: other.id})

    assert Repo.reload!(c.parent).sandbox_id == c.source.id
  end

  test "fresh replacement cannot retire a source with an uncertain provider operation", c do
    {:ok, operation} = SandboxTransitions._unsafe_submit(c.source, {:park, :idle})
    {:ok, _} = SandboxOperations._unsafe_mark_uncertain(operation.id)
    source = Repo.reload!(c.source)

    attrs = %{
      user_id: c.user.id,
      agent_id: c.agent.id,
      mode: source.mode,
      sprite_name: "local-fenced-#{Ecto.UUID.generate()}",
      status: "pending"
    }

    assert {:error, :provider_operation_fenced} =
             Conversations.ActorLaunches.replace(c.parent, source, attrs)

    assert Repo.reload!(c.parent).sandbox_id == source.id
    assert Repo.reload!(source).status == source.status
    assert Repo.reload!(operation).state == "uncertain"
    assert Repo.reload!(c.creation).holds_slot
    assert Repo.aggregate(Conversations.ActorLaunch, :count) == 0
  end

  test "an unresolved create refuses attachment even after a stale ready write", c do
    sandbox = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "pending")
    {:ok, parent} = Conversations.create_conversation(attrs(sandbox, c.agent))
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, parent)
    {:ok, _} = SandboxOperations._unsafe_mark_uncertain(creation.id)
    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})

    assert {:error, :provider_operation_fenced} =
             Conversations.create_conversation(attrs(sandbox, c.agent))
  end

  test "stale and foreign repoints cannot overwrite the winning binding", c do
    {other, _, _} = managed(c.user, c.agent)

    {:ok, moved} =
      Conversations.update_conversation(c.parent, %{sandbox_id: other.id, title: "winner"})

    assert {:error, :ownership_changed} =
             Conversations.update_conversation(c.parent, %{title: "stale"})

    assert {:error, :ownership_changed} =
             Conversations.update_conversation(moved, %{user_id: insert_verified_user().id})

    assert Repo.reload!(c.parent).title == "winner"
    assert {:ok, renamed} = Conversations.update_conversation(moved, %{title: "fresh"})
    assert renamed.sandbox_id == other.id
  end

  test "transferring a holder with a running turn or unresolved execution is refused", c do
    {other, _, _} = managed(c.user, c.agent)
    turn = insert_turn(c.parent, status: "running", started_at: DateTime.utc_now())

    assert {:error, :sandbox_mid_turn} =
             Conversations.update_conversation(c.parent, %{sandbox_id: other.id})

    {:ok, _} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    turn |> Ecto.Changeset.change(status: "completed") |> Repo.update!()

    assert {:error, :sandbox_mid_turn} =
             Conversations.update_conversation(c.parent, %{sandbox_id: other.id})
  end

  test "retired destinations and ownership drift cannot acquire holders", c do
    {other, _, _} = managed(c.user, c.agent)
    {:ok, retired} = Conversations.update_sandbox(other, %{status: "terminated"})

    assert {:error, {:sandbox_not_attachable, "terminated"}} =
             Conversations.update_conversation(c.parent, %{sandbox_id: retired.id})

    assert {:error, {:sandbox_not_attachable, "terminated"}} =
             Conversations.create_conversation(attrs(retired, c.agent))

    c.source
    |> Ecto.Changeset.change(provider_instance_id: "different-instance")
    |> Repo.update!()

    assert {:error, :provider_operation_fenced} =
             Conversations.create_conversation(attrs(c.source, c.agent))
  end

  test "credential-free machines cannot gain a credential-bearing cotenant", c do
    sandbox = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "pending")

    assert {:ok, _} =
             Conversations.create_conversation(
               Map.put(attrs(sandbox, c.agent), :sandbox_api_access, "none")
             )

    {:ok, ready} = Conversations.update_sandbox(sandbox, %{status: "ready"})

    assert {:error, :invalid_sandbox_api_access} =
             Conversations.create_conversation(attrs(ready, c.agent))

    assert {:error, :invalid_sandbox_api_access} =
             Conversations.update_conversation(c.parent, %{sandbox_id: ready.id})
  end

  test "replacement selects current holders and commits notification jobs with the move", c do
    {:ok, sibling} = Conversations.create_conversation(attrs(c.source, c.agent))
    {destination, _, _} = managed(c.user, c.agent)
    {:ok, _} = Conversations.update_sandbox(c.source, %{status: "terminated"})
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{sibling.id}")

    assert {:ok, moved} = SandboxHolders._unsafe_replace(c.parent, destination.id)
    assert moved.sandbox_id == destination.id
    id = sibling.id
    assert Repo.reload!(sibling).sandbox_id == destination.id
    assert Repo.reload!(c.creation).holds_slot
    refute_receive {:log_event, _}
    event = Repo.one!(LogEvent)

    job =
      Repo.one!(
        from j in Oban.Job, where: j.worker == "Fountain.Workers.TurnDeadlineNotification"
      )

    expect(Conversations.ConversationServer, :whereis, fn ^id -> self() end)
    assert :ok = Fountain.Workers.TurnDeadlineNotification.perform(job)
    assert_receive {:log_event, ^event}
    assert_receive {:"$gen_cast", {:machine_replaced, source, target}}
    assert {source, target} == {c.source.id, destination.id}

    assert {:error, :ownership_changed} = SandboxHolders._unsafe_replace(c.parent, destination.id)

    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "an outer rollback leaves every cotenant and notification unchanged", c do
    {:ok, sibling} = Conversations.create_conversation(attrs(c.source, c.agent))
    {destination, _, _} = managed(c.user, c.agent)
    {:ok, _} = Conversations.update_sandbox(c.source, %{status: "terminated"})

    assert {:error, :synthetic} =
             Repo.transaction(fn ->
               {:ok, _} =
                 SandboxHolders._unsafe_replace(c.parent, destination.id)

               Repo.rollback(:synthetic)
             end)

    assert Repo.reload!(sibling).sandbox_id == c.source.id
    assert Repo.reload!(c.parent).sandbox_id == c.source.id
    assert Repo.aggregate(LogEvent, :count) == 0

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "Fountain.Workers.TurnDeadlineNotification"),
             :count
           ) == 0
  end

  test "batch replacement refuses a still-live source, stale initiator, or busy cotenant", c do
    {:ok, sibling} = Conversations.create_conversation(attrs(c.source, c.agent))
    {destination, _, _} = managed(c.user, c.agent)

    assert {:error, :sandbox_not_retired} =
             SandboxHolders._unsafe_replace(c.parent, destination.id)

    {:ok, _} = Conversations.update_sandbox(c.source, %{status: "terminated"})
    insert_turn(sibling, status: "running")

    assert {:error, :sandbox_mid_turn} =
             SandboxHolders._unsafe_replace(c.parent, destination.id)

    assert Repo.reload!(c.parent).sandbox_id == c.source.id

    assert Repo.reload!(sibling).sandbox_id == c.source.id
  end

  test "a delayed replacement message never stops the destination or a newer binding", c do
    {destination, _, _} = managed(c.user, c.agent)
    {newest, _, _} = managed(c.user, c.agent)
    {:ok, moved} = Conversations.update_conversation(c.parent, %{sandbox_id: destination.id})

    state = %{
      conversation_id: c.parent.id,
      user_id: c.user.id,
      sandbox_id: destination.id,
      handle: :held
    }

    reject_drop = fn _, _ -> flunk("stale notification dropped the active connection") end

    assert {:noreply, ^state} =
             Lifecycle.replace_server(state, c.source.id, destination.id, reject_drop)

    {:ok, _} = Conversations.update_conversation(moved, %{sandbox_id: newest.id})
    old = %{state | sandbox_id: c.source.id}

    assert {:noreply, ^old} =
             Lifecycle.replace_server(old, c.source.id, destination.id, reject_drop)
  end

  test "legacy identity requires unanimous historical lineage", c do
    legacy = insert_sandbox(user_id: c.user.id, status: "ready")
    insert_conversation(user_id: c.user.id, agent: c.agent, sandbox: legacy, status: "terminated")
    assert {:ok, _} = Conversations.create_conversation(attrs(legacy, c.agent))

    assert {:error, :sandbox_identity_mismatch} =
             Conversations.create_conversation(%{attrs(legacy, c.agent) | agent_id: nil})

    other = insert_agent(user_id: c.user.id)
    insert_conversation(user_id: c.user.id, agent: other, sandbox: legacy, status: "terminated")

    assert {:error, :sandbox_identity_mismatch} =
             Conversations.create_conversation(attrs(legacy, c.agent))
  end

  test "a matching replacement message closes only the original actor connection", c do
    {destination, _, _} = managed(c.user, c.agent)
    {:ok, _} = Conversations.update_conversation(c.parent, %{sandbox_id: destination.id})

    state = %{
      conversation_id: c.parent.id,
      user_id: c.user.id,
      sandbox_id: c.source.id,
      handle: :held
    }

    owner = self()

    assert {:stop, :normal, %{handle: nil}} =
             Lifecycle.replace_server(state, c.source.id, destination.id, fn original, event ->
               assert original == state
               assert event == "replaced"
               send(owner, :dropped)
               original
             end)

    assert_receive :dropped
  end

  test "an old actor cannot open autonomous work after its holder moves", c do
    {destination, _, _} = managed(c.user, c.agent)
    {:ok, moved} = Conversations.update_conversation(c.parent, %{sandbox_id: destination.id})

    assert {:error, :ownership_changed} =
             Fountain.Conversations.Connection.open_autonomous_turn(
               moved.id,
               c.user.id,
               c.source.id
             )

    assert Repo.aggregate(Fountain.Conversations.Turn, :count) == 0
  end

  defp managed(user, agent) do
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "pending")
    {:ok, parent} = Conversations.create_conversation(attrs(sandbox, agent))
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, parent)

    handle = %Handle{
      provider: :sprites,
      name: sandbox.sprite_name,
      instance_id: Ecto.UUID.generate()
    }

    {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})
    {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, parent)
    {age_sandbox_activity(sandbox), parent, creation}
  end

  defp attrs(sandbox, agent),
    do: %{
      sandbox_id: sandbox.id,
      user_id: sandbox.user_id,
      agent_id: agent.id,
      runtime: agent.runtime,
      status: "idle"
    }
end
