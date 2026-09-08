defmodule Fountain.Conversations.ProvisionWatchdogTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{ExecutionGuard, LogEvent, ProvisionWatchdog, SandboxOperations}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "starting")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "pending")

    {:ok, {endpoint, _}} =
      Fountain.Webhooks.create_endpoint(user.id, %{"url" => "https://hooks.example.com/provision"})

    %{user: user, sandbox: sandbox, conv: conv, endpoint: endpoint}
  end

  test "expiry commits one failure and durable notification before any broadcast", c do
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")
    assert {:ok, :expired} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert Repo.reload!(c.conv).status == "failed"
    assert Repo.reload!(c.sandbox).status == "failed"
    event = Repo.one!(LogEvent)
    assert event.stage == "provision"
    assert event.state == "failed"
    assert Jason.decode!(event.data)["sandbox_id"] == c.sandbox.id
    refute_receive {:log_event, _}

    job =
      Repo.one!(
        from j in Oban.Job, where: j.worker == "Fountain.Workers.TurnDeadlineNotification"
      )

    assert :ok = Fountain.Workers.TurnDeadlineNotification.perform(job)
    assert_receive {:log_event, ^event}
    assert {:ok, :settled} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "rollback leaves both rows and all notifications unchanged", c do
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, :expired} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
               Repo.rollback(:abort)
             end)

    assert Repo.reload!(c.conv).status == "pending"
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.aggregate(LogEvent, :count) == 0

    refute Repo.exists?(
             from j in Oban.Job, where: j.worker == "Fountain.Workers.TurnDeadlineNotification"
           )

    refute_receive {:log_event, _}
  end

  test "a rejected webhook enqueue rolls back the entire timeout", c do
    expect(Fountain.Workers.WebhookDelivery, :enqueue, fn _, _ -> {:error, :queue_unavailable} end)

    assert_raise MatchError, fn -> ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id) end
    assert Repo.reload!(c.conv).status == "pending"
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.aggregate(LogEvent, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.WebhookDelivery) == []
    assert all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification) == []
  end

  test "moving the parent suppresses the old timeout", c do
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")

    {:ok, _} =
      Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id, status: "idle"})

    assert {:ok, :stale} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert Repo.reload!(c.conv).status == "idle"
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.reload!(replacement).status == "ready"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "foreign or missing rows cannot authorize a timeout", c do
    c.sandbox |> change(user_id: insert_verified_user().id) |> Repo.update!()
    assert {:ok, :stale} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert {:ok, :stale} = ProvisionWatchdog._unsafe_expire(Ecto.UUID.generate(), c.sandbox.id)
    assert {:ok, :stale} = ProvisionWatchdog._unsafe_expire(c.conv.id, Ecto.UUID.generate())
    assert Repo.reload!(c.conv).status == "pending"
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "successful or retired provisioning is left alone", c do
    for status <- ~w(ready suspended terminated failed) do
      {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: status})
      assert {:ok, :settled} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
      assert Repo.reload!(c.sandbox).status == status
    end

    assert Repo.reload!(c.conv).status == "pending"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "a running cotenant protects the shared machine", c do
    peer = insert_conversation(user_id: c.user.id, sandbox: c.sandbox)
    turn = insert_turn(peer, status: "running")
    assert {:ok, :settled} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.reload!(turn).status == "running"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "unresolved execution protects a machine after its turn ends", c do
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "ready"})
    turn = insert_turn(c.conv, status: "running", started_at: DateTime.utc_now())

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)
    {:ok, _} = ExecutionGuard._unsafe_complete(execution.id, "interrupted")
    assert Repo.reload!(turn).status == "failed"
    # A stale setup write must not make an unresolved remote execution disposable.
    c.sandbox |> Repo.reload!() |> change(status: "starting") |> Repo.update!()
    assert {:ok, :settled} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.reload!(execution).state == "awaiting_identity"
  end

  test "timeout retains uncertain creation and its capacity", c do
    {:ok, creation} = SandboxOperations._unsafe_submit_create(c.sandbox, c.conv)
    assert creation.state == "uncertain"
    assert {:ok, :expired} = ProvisionWatchdog._unsafe_expire(c.conv.id, c.sandbox.id)
    assert Repo.reload!(creation).state == "uncertain"
    assert Repo.reload!(creation).holds_slot
    assert Fountain.Quotas.active_sandbox_count(c.user.id) == 1

    assert {:error, _} =
             SandboxOperations._unsafe_submit_create(
               Repo.reload!(c.sandbox),
               Repo.reload!(c.conv)
             )

    assert Repo.reload!(creation).state == "uncertain"
  end
end
