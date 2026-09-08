defmodule Fountain.Conversations.ActorOwnershipTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  alias Fountain.Conversations.{
    ActorClaim,
    ActorOwnership,
    ExecutionGuard,
    LogEvent,
    PromptDelivery,
    ProvisionContext,
    ProvisionWatchdog
  }

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox)
    id = Ecto.UUID.generate()
    state = %{user_id: user.id, conversation_id: conv.id, sandbox_id: sandbox.id, actor_claim: id}
    %{user: user, sandbox: sandbox, conv: conv, id: id, state: state}
  end

  defp claim(c, id), do: ActorOwnership.claim(c.user.id, c.conv.id, c.sandbox.id, id)

  test "one incarnation owns startup and duplicate delivery of its claim is idempotent", c do
    assert {:ok, first} = claim(c, c.id)
    assert {:ok, replay} = claim(c, c.id)
    assert replay.id == first.id
    assert {:error, :actor_owned} = claim(c, Ecto.UUID.generate())
    assert Repo.aggregate(ActorClaim, :count) == 1
  end

  test "elapsed time cannot authorize taking over an unresolved actor", c do
    {:ok, owner} = claim(c, c.id)
    owner |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z]) |> Repo.update!()
    assert {:error, :actor_owned} = claim(c, Ecto.UUID.generate())
    assert Repo.reload!(owner).state == "active"
  end

  test "claim validates the tenant and original binding before reserving ownership", c do
    assert {:error, :ownership_changed} =
             ActorOwnership.claim(Ecto.UUID.generate(), c.conv.id, c.sandbox.id, c.id)

    other = insert_sandbox(user_id: c.user.id, status: "ready")

    assert {:error, :ownership_changed} =
             ActorOwnership.claim(c.user.id, c.conv.id, other.id, c.id)

    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  test "completed local teardown releases the claim and an old ID cannot resurrect", c do
    {:ok, owner} = claim(c, c.id)
    parent = self()
    assert :ok = ActorOwnership.finish(c.state, fn -> send(parent, :teardown) end)
    assert_received :teardown
    assert Repo.reload!(owner).state == "stopped"
    assert {:error, :actor_retired} = claim(c, c.id)
    assert {:ok, _} = claim(c, Ecto.UUID.generate())
  end

  test "failed local teardown retains ownership for recovery", c do
    {:ok, owner} = claim(c, c.id)

    assert_raise RuntimeError, "local teardown failed", fn ->
      ActorOwnership.finish(c.state, fn -> raise "local teardown failed" end)
    end

    assert Repo.reload!(owner).state == "active"
    assert {:error, :actor_owned} = claim(c, Ecto.UUID.generate())
  end

  test "same-machine successor rejects predecessor stages, failure, interruption and watchdog",
       c do
    {:ok, _} = claim(c, c.id)
    old_context = ProvisionContext.new(c.conv, c.sandbox, c.id)
    assert :ok = ActorOwnership.finish(c.state, fn -> :ok end)
    successor = Ecto.UUID.generate()
    {:ok, _} = claim(c, successor)
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.conv.id, "next request", [])

    assert ProvisionContext.stage(old_context, "setup", "failed") == nil
    assert ProvisionContext.output(old_context, "setup", "late output") == nil
    assert {:error, :ownership_changed} = ProvisionContext.fail(old_context, %{reason: "late"})

    assert {:error, :ownership_changed} =
             ExecutionGuard._unsafe_interrupt_on_sandbox(c.conv.id, c.sandbox.id, c.id)

    assert {:ok, :stale} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id, c.id)
    assert Repo.reload!(receipt).state == "queued"
    assert Repo.reload!(c.sandbox).status == "ready"
    assert Repo.aggregate(LogEvent, :count) == 0
    assert ActorOwnership.current?(c.conv.id, c.sandbox.id, successor)
  end

  test "omitting the incarnation cannot bypass an existing actor claim", c do
    {:ok, _} = claim(c, c.id)
    context = ProvisionContext.new(c.conv, c.sandbox)
    assert ProvisionContext.stage(context, "setup", "failed") == nil
    assert {:ok, :stale} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)

    assert {:error, :ownership_changed} =
             ExecutionGuard._unsafe_interrupt_on_sandbox(c.conv.id, c.sandbox.id)

    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "a committed transfer supersedes only the old binding and skips its shared teardown", c do
    {:ok, owner} = claim(c, c.id)
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")
    {:ok, moved} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})
    successor = Ecto.UUID.generate()
    assert {:ok, next} = ActorOwnership.claim(c.user.id, moved.id, replacement.id, successor)
    assert Repo.reload!(owner).state == "superseded"

    assert :ok = ActorOwnership.finish(c.state, fn -> flunk("stale teardown") end)
    assert Repo.reload!(next).state == "active"
    assert ActorOwnership.current?(moved.id, replacement.id, successor)
  end

  test "reusing a retired ID rolls back superseding the current owner", c do
    {:ok, _} = claim(c, c.id)
    assert :ok = ActorOwnership.finish(c.state, fn -> :ok end)
    current_id = Ecto.UUID.generate()
    {:ok, current} = claim(c, current_id)
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")
    {:ok, moved} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})

    assert {:error, :actor_retired} =
             ActorOwnership.claim(c.user.id, moved.id, replacement.id, c.id)

    assert Repo.reload!(current).state == "active"
  end

  test "stages inside actor teardown are delivered only after commit", c do
    {:ok, _} = claim(c, c.id)
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")

    :ok =
      ActorOwnership.finish(c.state, fn ->
        Conversations.publish_stage(c.conv.id, "reattach", "interrupted")
        refute_received {:log_event, _}
      end)

    refute_received {:log_event, _}
    assert [job] = all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)
    assert :ok = perform_job(Fountain.Workers.TurnDeadlineNotification, job.args)
    assert_receive {:log_event, %{stage: "reattach", state: "interrupted"}}
  end

  test "rolled-back actor teardown emits no stage and retains the claim", c do
    {:ok, owner} = claim(c, c.id)
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")

    assert_raise RuntimeError, "local teardown failed", fn ->
      ActorOwnership.finish(c.state, fn ->
        Conversations.publish_stage(c.conv.id, "reattach", "interrupted")
        raise "local teardown failed"
      end)
    end

    refute_received {:log_event, _}
    assert Repo.aggregate(LogEvent, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification) == []
    assert Repo.reload!(owner).state == "active"
  end

  test "another tenant cannot tear down or release the saved actor claim", c do
    {:ok, owner} = claim(c, c.id)
    forged = %{c.state | user_id: Ecto.UUID.generate()}
    assert :ok = ActorOwnership.finish(forged, fn -> flunk("foreign teardown") end)
    assert Repo.reload!(owner).state == "active"
  end

  test "an unclaimed starting machine requires reconciliation, including legacy rows", c do
    c.sandbox |> change(status: "starting") |> Repo.update!()
    assert {:error, :provisioning_unresolved} = claim(c, c.id)
    assert Repo.aggregate(ActorClaim, :count) == 0
  end

  for status <- ~w(pending starting) do
    test "a stopped claim cannot authorize another create on a #{status} machine", c do
      c.sandbox |> change(status: "pending") |> Repo.update!()
      {:ok, owner} = claim(c, c.id)
      c.sandbox |> change(status: unquote(status)) |> Repo.update!()
      assert :ok = ActorOwnership.finish(c.state, fn -> :ok end)
      assert Repo.reload!(owner).state == "stopped"
      assert {:error, :actor_retired} = claim(c, c.id)
      assert {:error, :provisioning_unresolved} = claim(c, Ecto.UUID.generate())
      assert Repo.aggregate(ActorClaim, :count) == 1
    end
  end

  test "a different parent cannot bypass a pending machine's claim history", c do
    c.sandbox |> change(status: "pending") |> Repo.update!()
    {:ok, _} = claim(c, c.id)
    other = insert_conversation(user_id: c.user.id, sandbox: Repo.reload!(c.sandbox))

    assert {:error, :provisioning_unresolved} =
             ActorOwnership.claim(c.user.id, other.id, c.sandbox.id, Ecto.UUID.generate())

    assert :ok = ActorOwnership.finish(c.state, fn -> :ok end)

    assert {:error, :provisioning_unresolved} =
             ActorOwnership.claim(c.user.id, other.id, c.sandbox.id, Ecto.UUID.generate())
  end

  test "a refused target cannot supersede the old actor's claim", c do
    {:ok, owner} = claim(c, c.id)
    target = insert_sandbox(user_id: c.user.id, status: "pending")
    {:ok, moved} = Conversations.update_conversation(c.conv, %{sandbox_id: target.id})
    target |> change(status: "starting") |> Repo.update!()

    assert {:error, :provisioning_unresolved} =
             ActorOwnership.claim(c.user.id, moved.id, target.id, Ecto.UUID.generate())

    assert Repo.reload!(owner).state == "active"
  end

  test "the existing incarnation can re-read its claim after provisioning starts", c do
    c.sandbox |> change(status: "pending") |> Repo.update!()
    {:ok, owner} = claim(c, c.id)
    c.sandbox |> change(status: "starting") |> Repo.update!()
    assert {:ok, replay} = claim(c, c.id)
    assert replay.id == owner.id
    assert {:error, :actor_owned} = claim(c, Ecto.UUID.generate())
  end

  test "startup returns the rows authorized under lock instead of stale pending snapshots", c do
    stale = %{c.sandbox | status: "pending"}
    c.conv |> change(title: "Current parent") |> Repo.update!()

    assert {:ok, claimed, parent, sandbox} =
             ActorOwnership.start(c.state, c.conv, stale, 30_000)

    assert claimed.actor_claim == c.id
    assert parent.title == "Current parent"
    assert sandbox.status == "ready"
    assert sandbox.id == stale.id
  end
end
