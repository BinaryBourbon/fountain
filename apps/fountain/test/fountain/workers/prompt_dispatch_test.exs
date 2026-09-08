defmodule Fountain.Workers.PromptDispatchTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{ConversationServer, LogEvent, PromptDelivery, Turn}
  alias Fountain.Workers.PromptDispatch

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "Review", [], idempotency_key: "key")
    [job] = all_enqueued(worker: PromptDispatch)
    %{user: user, sandbox: sandbox, conv: conv, receipt: receipt, job: job}
  end

  defp expire(receipt),
    do:
      receipt
      |> change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), -1))
      |> Repo.update!()

  test "a missing actor retains dispatch until a later notification is claimed", c do
    expect(ConversationServer, :whereis, fn _ -> nil end)
    assert {:snooze, 15} = perform_job(PromptDispatch, c.job.args)
    assert Repo.reload!(c.receipt).state == "queued"
    assert Repo.reload!(c.sandbox).status == "ready"

    # The first submitter is gone. Only the persisted job supplies the receipt.
    expect(ConversationServer, :whereis, fn id ->
      assert id == c.conv.id
      self()
    end)

    assert {:snooze, 15} = perform_job(PromptDispatch, c.job.args)
    id = c.receipt.id
    assert_receive {:"$gen_cast", {:prompt_receipt, ^id}}
    assert {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, id, c.sandbox.id)
    assert :ok = perform_job(PromptDispatch, c.job.args)
    assert turn.id == c.receipt.turn_id
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "an unacknowledged notification is retried, not treated as delivery", c do
    expect(ConversationServer, :whereis, 2, fn _ -> self() end)
    id = c.receipt.id

    for _ <- 1..2 do
      assert {:snooze, 15} = perform_job(PromptDispatch, c.job.args)
      assert_receive {:"$gen_cast", {:prompt_receipt, ^id}}
    end

    assert Repo.reload!(c.receipt).state == "queued"
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "expiry records one failure without changing uncertain provisioning", c do
    c.sandbox |> change(status: "starting") |> Repo.update!()
    expire(c.receipt)
    reject(ConversationServer, :whereis, 1)

    assert :ok = perform_job(PromptDispatch, c.job.args)
    assert :ok = perform_job(PromptDispatch, c.job.args)
    assert Repo.reload!(c.receipt).failure_reason == "delivery_expired"
    assert Repo.get!(Turn, c.receipt.turn_id).status == "failed"
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.aggregate(LogEvent, :count) == 1
    assert length(all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)) == 1

    assert {:ok, replay} =
             PromptDelivery.submit(c.user.id, c.conv.id, "Review", [], idempotency_key: "key")

    assert replay.id == c.receipt.id
    assert replay.state == "refused"
  end

  test "a delayed actor cannot claim an expired receipt before the job runs", c do
    expire(c.receipt)

    assert {:error, :delivery_expired} =
             PromptDelivery._unsafe_activate(c.conv.id, c.receipt.id, c.sandbox.id)

    assert Repo.get!(Turn, c.receipt.turn_id).status == "pending"
    assert :ok = perform_job(PromptDispatch, c.job.args)
    assert Repo.get!(Turn, c.receipt.turn_id).started_at == nil
  end

  test "a premature expiry cannot refuse a valid queued prompt", c do
    assert {:error, :delivery_not_expired} =
             PromptDelivery.refuse(c.user.id, c.conv.id, c.receipt.id, "delivery_expired")

    assert Repo.reload!(c.receipt).state == "queued"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "a claim before expiry is never failed or replayed by dispatch", c do
    {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, c.receipt.id, c.sandbox.id)
    expire(Repo.reload!(c.receipt))
    reject(ConversationServer, :whereis, 1)
    assert :ok = perform_job(PromptDispatch, c.job.args)
    assert Repo.reload!(turn).status == "running"
    assert Repo.reload!(c.receipt).state == "claimed"

    Repo.delete!(turn)
    assert :ok = perform_job(PromptDispatch, c.job.args)
    assert Repo.aggregate(Turn, :count) == 0
  end

  test "a job cannot use another tenant's receipt", c do
    other = insert_verified_user()
    reject(ConversationServer, :whereis, 1)
    assert :ok = perform_job(PromptDispatch, Map.put(c.job.args, "user_id", other.id))
    assert Repo.reload!(c.receipt).state == "queued"
  end
end
