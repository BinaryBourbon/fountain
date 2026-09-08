defmodule Fountain.Workers.PromptDispatchSweepTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{ConversationServer, LogEvent, PromptDelivery, Turn}
  alias Fountain.Workers.{PromptDispatch, PromptDispatchSweep}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "Review", [])
    [job] = all_enqueued(worker: PromptDispatch)
    %{user: user, sandbox: sandbox, conv: conv, receipt: receipt, job: job}
  end

  for state <- ["executing", "discarded", "missing"] do
    test "a #{state} original job cannot strand a queued receipt", c do
      state = unquote(state)

      if state == "missing" do
        Repo.delete!(c.job)
      else
        c.job
        |> change(state: state, attempted_at: DateTime.add(DateTime.utc_now(), -120))
        |> Repo.update!()
      end

      before = Repo.get(Oban.Job, c.job.id)

      expect(ConversationServer, :whereis, fn id ->
        assert id == c.conv.id
        self()
      end)

      assert :ok = perform_job(PromptDispatchSweep, %{})
      receipt_id = c.receipt.id
      assert_receive {:"$gen_cast", {:prompt_receipt, ^receipt_id}}
      assert Repo.get(Oban.Job, c.job.id) == before
      assert Repo.reload!(c.receipt).state == "queued"
      assert Repo.aggregate(Turn, :count) == 1
    end
  end

  test "repeated sweeps preserve healthy jobs and never create more dispatch jobs", c do
    expect(ConversationServer, :whereis, 2, fn _ -> self() end)
    for _ <- 1..2, do: assert(:ok == perform_job(PromptDispatchSweep, %{}))
    assert length(all_enqueued(worker: PromptDispatch)) == 1
    assert Repo.reload!(c.job) == c.job
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "expired intent records one failure even when its original job is stuck", c do
    c.job |> change(state: "executing") |> Repo.update!()

    c.receipt
    |> change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    reject(ConversationServer, :whereis, 1)

    assert :ok = perform_job(PromptDispatchSweep, %{})
    assert :ok = perform_job(PromptDispatchSweep, %{})
    assert Repo.reload!(c.receipt).failure_reason == "delivery_expired"
    assert Repo.get!(Turn, c.receipt.turn_id).status == "failed"
    assert Repo.aggregate(LogEvent, :count) == 1
    assert Repo.reload!(c.job).state == "executing"
  end

  test "already claimed intent cannot be replayed by recovery", c do
    {:ok, _} = PromptDelivery._unsafe_activate(c.conv.id, c.receipt.id, c.sandbox.id)
    Repo.delete!(c.job)
    reject(ConversationServer, :whereis, 1)
    assert :ok = perform_job(PromptDispatchSweep, %{})
    assert Repo.reload!(c.receipt).state == "claimed"
    assert all_enqueued(worker: PromptDispatch) == []
  end

  test "recovery requires the parent's current tenant to match the saved receipt", c do
    other = insert_verified_user()
    c.conv |> change(user_id: other.id) |> Repo.update!()
    reject(ConversationServer, :whereis, 1)
    assert :ok = perform_job(PromptDispatchSweep, %{})
    assert Repo.reload!(c.receipt).state == "queued"
  end

  test "a failed dispatch cannot starve later receipts or the next page", c do
    receipts =
      [
        c.receipt
        | for _ <- 1..100 do
            conv = insert_conversation(user_id: c.user.id, sandbox: c.sandbox, status: "idle")
            {:ok, receipt} = PromptDelivery.submit(c.user.id, conv.id, "Page proof", [])
            receipt
          end
      ]
      |> Enum.sort_by(& &1.id)

    failed_conv = hd(receipts).conversation_id

    stub(ConversationServer, :whereis, fn id ->
      # The next page must already be durable before any notification can block.
      assert length(all_enqueued(worker: PromptDispatchSweep)) == 1
      if id == failed_conv, do: raise("offline dispatch failure")
      self()
    end)

    assert {:error, {:prompt_dispatch_failed, 1}} = perform_job(PromptDispatchSweep, %{})
    [next] = all_enqueued(worker: PromptDispatchSweep)
    assert next.args["after_receipt_id"] == Enum.at(receipts, 99).id
    assert :ok = perform_job(PromptDispatchSweep, next.args)

    for receipt <- tl(receipts) do
      id = receipt.id
      assert_receive {:"$gen_cast", {:prompt_receipt, ^id}}
    end

    assert length(all_enqueued(worker: PromptDispatch)) == 101
  end
end
