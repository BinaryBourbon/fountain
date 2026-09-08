defmodule Fountain.Conversations.PromptDeliveryTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations

  alias Fountain.Conversations.{
    ExecutionGuard,
    ExecutionLimits,
    LogEvent,
    PromptDelivery,
    PromptReceipt,
    Turn,
    TurnExecution,
    TurnImage
  }

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{user: user, sandbox: sandbox, conv: conv}
  end

  defp submit(c, prompt \\ "Review this PR", images \\ [], key \\ "stable-request"),
    do: PromptDelivery.submit(c.user.id, c.conv.id, prompt, images, idempotency_key: key)

  test "acceptance commits before wake and a lost response cannot repeat it", c do
    stub(Conversations.ConversationServer, :whereis, fn _ -> nil end)

    expect(Conversations, :wake_conversation, fn id ->
      assert id == c.conv.id
      assert PromptDelivery.queued(c.user.id, id)
      assert length(all_enqueued(worker: Fountain.Workers.PromptDispatch)) == 1
      raise "offline lost wake response"
    end)

    assert_raise RuntimeError, "offline lost wake response", fn ->
      PromptDelivery.accept(c.user.id, c.conv.id, "Review", [], idempotency_key: "lost")
    end

    receipt = PromptDelivery.queued(c.user.id, c.conv.id)

    assert {:ok, retry} =
             PromptDelivery.accept(c.user.id, c.conv.id, "Review", [], idempotency_key: "lost")

    assert retry.id == receipt.id
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "acceptance cannot notify before an outer transaction commits", c do
    reject(Conversations.ConversationServer, :whereis, 1)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn ->
               PromptDelivery.accept(c.user.id, c.conv.id, "Review", [])
             end)

    assert Repo.aggregate(Turn, :count) == 0
  end

  test "registry timeout during pending provisioning cannot create a replacement", c do
    agent = insert_agent(user_id: c.user.id)
    c.conv |> change(agent_id: agent.id, status: "pending") |> Repo.update!()
    c.sandbox |> change(status: "starting") |> Repo.update!()
    expect(Conversations.ConversationServer, :await_registered, fn _ -> :timeout end)
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert {:error, :provisioning} = Conversations.wake_conversation(c.conv.id)
    assert Repo.reload!(c.conv).sandbox_id == c.sandbox.id
    assert Repo.reload!(c.sandbox).status == "starting"
  end

  test "receipt, pending turn and ordered images commit as one submission", c do
    images = [
      %{media_type: "image/png", data: <<0, 1, 2>>},
      %{media_type: "image/jpeg", data: <<3, 4>>}
    ]

    assert {:ok, receipt} = submit(c, "Review these", images)
    turn = Repo.get!(Turn, receipt.turn_id)
    assert receipt.state == "queued"
    assert DateTime.diff(receipt.delivery_deadline_at, receipt.inserted_at) in 2099..2100
    [job] = all_enqueued(worker: Fountain.Workers.PromptDispatch)

    assert job.args == %{
             "receipt_id" => receipt.id,
             "conversation_id" => c.conv.id,
             "user_id" => c.user.id
           }

    assert turn.prompt == "Review these"
    assert turn.status == "pending"
    assert turn.started_at == nil
    assert turn.turn_number == 1
    stored = Repo.all(from i in TurnImage, order_by: i.position)
    assert Enum.map(stored, &Map.take(&1, [:data, :media_type])) == images
    assert Repo.reload!(c.conv).status == "idle"
    assert Repo.aggregate(TurnExecution, :count) == 0
  end

  test "repeating the same key returns the same receipt without duplicating images", c do
    images = [%{media_type: "image/png", data: <<1, 2>>}]
    {:ok, first} = submit(c, "Review", images)
    assert {:ok, again} = submit(c, "Review", images)
    assert first.id == again.id
    assert first.delivery_deadline_at == again.delivery_deadline_at
    assert length(all_enqueued(worker: Fountain.Workers.PromptDispatch)) == 1
    assert Repo.aggregate(Turn, :count) == 1
    assert Repo.aggregate(TurnImage, :count) == 1
    refute inspect(first) =~ "stable-request"
  end

  test "a key cannot silently choose different text, bytes or image order", c do
    images = [%{media_type: "image/png", data: <<1>>}, %{media_type: "image/png", data: <<2>>}]
    {:ok, _} = submit(c, "Review", images)
    assert {:error, :idempotency_conflict} = submit(c, "Different", images)
    assert {:error, :idempotency_conflict} = submit(c, "Review", Enum.reverse(images))

    assert {:error, :idempotency_conflict} =
             submit(c, "Review", [%{media_type: "image/png", data: <<3>>}])

    assert Repo.aggregate(Turn, :count) == 1
  end

  test "tenant scope applies to submission, fetch and refusal", c do
    other = insert_verified_user()
    assert {:error, :not_found} = PromptDelivery.submit(other.id, c.conv.id, "foreign", [])
    {:ok, receipt} = submit(c)
    assert PromptDelivery.fetch(other.id, c.conv.id, receipt.id) == nil

    assert {:error, :not_found} =
             PromptDelivery.refuse(other.id, c.conv.id, receipt.id, "cancelled")

    assert PromptDelivery.fetch(c.user.id, c.conv.id, receipt.id).id == receipt.id
  end

  test "a second distinct request is refused while the first is queued or running", c do
    {:ok, receipt} = submit(c)
    assert {:error, :busy} = submit(c, "second", [], "second-key")
    assert {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
    assert turn.id == receipt.turn_id
    assert {:error, :busy} = submit(c, "second", [], "second-key")
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "activation claims the existing turn once and later attempts grant no work", c do
    {:ok, receipt} = submit(c)
    assert {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
    assert turn.status == "running"
    assert turn.started_at
    assert Repo.reload!(receipt).state == "claimed"
    assert Repo.reload!(receipt).sandbox_id == c.sandbox.id

    assert {:error, :delivery_claimed} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert {:error, :delivery_claimed} =
             PromptDelivery.refuse(c.user.id, c.conv.id, receipt.id, "cancelled")

    assert Repo.aggregate(Turn, :count) == 1
  end

  test "the executing wrapper refuses an outer transaction before claiming work", c do
    {:ok, receipt} = submit(c)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn ->
               Conversations._unsafe_activate_prompt_receipt(c.conv.id, receipt.id, c.sandbox.id)
             end)

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
  end

  test "bounded execution and the delivery claim roll back together", c do
    stub(ExecutionLimits, :enforced_controls, fn _ -> ExecutionLimits.keys() end)
    c.conv |> change(execution_limits: %{"wall_time_seconds" => 60}) |> Repo.update!()
    {:ok, receipt} = submit(c)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

               assert Repo.get_by!(TurnExecution, turn_id: receipt.turn_id)
               Repo.rollback(:abort)
             end)

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
    assert Repo.aggregate(TurnExecution, :count) == 0
    assert {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
    execution = Repo.get_by!(TurnExecution, turn_id: turn.id)
    assert DateTime.diff(execution.deadline_at, turn.started_at) == 60
  end

  test "a stale actor cannot claim a request after the parent moves", c do
    {:ok, receipt} = submit(c)
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")
    {:ok, _} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})

    assert {:error, :ownership_changed} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert Repo.reload!(receipt).state == "queued"
    assert {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, replacement.id)
    assert turn.id == receipt.turn_id
  end

  test "changed account policy prevents activation without losing the pending payload", c do
    {:ok, receipt} = submit(c)

    c.user
    |> change(suspended_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!()

    assert {:error, :account_suspended} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).prompt == "Review this PR"
  end

  test "activation uses the current runtime's machine capacity", c do
    {:ok, receipt} = submit(c)
    c.conv |> change(runtime: "gemini") |> Repo.update!()
    peer = insert_conversation(user_id: c.user.id, sandbox: c.sandbox, runtime: "gemini")
    insert_turn(peer, status: "running")

    assert {:error, :sandbox_at_capacity} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
  end

  test "legacy turn admission cannot overtake a saved prompt", c do
    {:ok, receipt} = submit(c)

    assert {:error, :busy} =
             Conversations._unsafe_create_turn_on_sandbox(
               %{
                 conversation_id: c.conv.id,
                 turn_number: 2,
                 prompt: "legacy",
                 status: "running"
               },
               c.sandbox.id,
               :unbounded
             )

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "legacy admission cannot overlap a claimed prompt", c do
    {:ok, receipt} = submit(c)
    assert {:ok, _} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert {:error, :busy} =
             Conversations._unsafe_create_turn_on_sandbox(
               %{
                 conversation_id: c.conv.id,
                 turn_number: 2,
                 prompt: "legacy",
                 status: "running"
               },
               c.sandbox.id,
               :unbounded
             )

    assert Repo.reload!(receipt).state == "claimed"
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "a running user turn admitted elsewhere prevents activation", c do
    {:ok, receipt} = submit(c)
    running = insert_turn(c.conv, turn_number: 2, status: "running")
    assert {:error, :busy} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
    assert Repo.reload!(running).status == "running"
    assert Repo.reload!(receipt).state == "queued"
  end

  test "invalid payloads and oversized keys create no partial transcript", c do
    assert {:error, :invalid_prompt} = submit(c, " ")

    assert {:error, :invalid_images} =
             submit(c, "Review", [%{media_type: "text/html", data: "bad"}])

    assert {:error, :invalid_images} = submit(c, "Review", [%{media_type: "image/png"}])

    assert {:error, :invalid_idempotency_key} =
             submit(c, "Review", [], String.duplicate("x", 201))

    assert Repo.aggregate(PromptReceipt, :count) == 0
    assert Repo.aggregate(Turn, :count) == 0
    assert Repo.aggregate(TurnImage, :count) == 0
  end

  test "an outer rollback leaves no receipt, turn, image or dispatch job", c do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = submit(c, "Review", [%{media_type: "image/png", data: <<1>>}])
               Repo.rollback(:abort)
             end)

    assert Repo.aggregate(PromptReceipt, :count) == 0
    assert Repo.aggregate(Turn, :count) == 0
    assert Repo.aggregate(TurnImage, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.PromptDispatch) == []
  end

  test "public interrupt cancels an accepted prompt even with no actor", c do
    {:ok, receipt} = submit(c)
    reject(Conversations.ConversationServer, :whereis, 1)
    assert :ok = Conversations.ConversationServer.interrupt(c.conv.id)
    assert Repo.reload!(receipt).failure_reason == "cancelled"
    assert Repo.get!(Turn, receipt.turn_id).status == "failed"

    assert {:error, :delivery_claimed} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
  end

  test "cancelling queued intent preserves interruption of an autonomous turn", c do
    insert_turn(c.conv, status: "running", origin: "autonomous")
    {:ok, receipt} = submit(c)
    assert {:ok, :unbounded} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    assert Repo.reload!(receipt).failure_reason == "cancelled"
  end

  test "startup retirement preserves queued intent for the starting actor", c do
    {:ok, receipt} = submit(c)

    assert {:ok, :unbounded} =
             ExecutionGuard._unsafe_interrupt_on_sandbox(c.conv.id, c.sandbox.id)

    assert Repo.reload!(receipt).state == "queued"
    assert {:ok, _} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
  end

  test "interrupt rollback restores queued intent and removes failure notification", c do
    {:ok, receipt} = submit(c)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, {:queued, _}} = ExecutionGuard._unsafe_interrupt(c.conv.id)
               Repo.rollback(:abort)
             end)

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
    assert Repo.aggregate(LogEvent, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification) == []
  end

  test "a conversation with an accepted prompt cannot release its machine", c do
    {:ok, _} = submit(c)

    assert {:error, :busy} =
             ExecutionGuard._unsafe_release_parent(c.conv.id, fn _ ->
               flunk("release must not discard accepted intent")
             end)
  end

  test "refusal preserves an outcome and notifies only after commit", c do
    {:ok, receipt} = submit(c)
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")

    assert {:ok, refused} =
             PromptDelivery.refuse(c.user.id, c.conv.id, receipt.id, "provisioning_failed")

    assert refused.state == "refused"
    turn = Repo.get!(Turn, receipt.turn_id)
    assert turn.status == "failed"
    assert turn.started_at == nil
    event = Repo.one!(LogEvent)
    assert event.turn_id == receipt.turn_id
    refute_receive {:log_event, _}
    [notification] = all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)
    assert :ok = perform_job(Fountain.Workers.TurnDeadlineNotification, notification.args)
    assert_receive {:log_event, ^event}
    assert {:ok, again} = submit(c)
    assert again.id == receipt.id
    assert again.state == "refused"

    assert {:error, :delivery_claimed} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
  end

  test "refusal rollback cannot leave the receipt and turn disagreeing", c do
    {:ok, receipt} = submit(c)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = PromptDelivery.refuse(c.user.id, c.conv.id, receipt.id, "cancelled")
               Repo.rollback(:abort)
             end)

    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
    assert Repo.aggregate(LogEvent, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification) == []
  end

  test "transcript retention cannot make an old key authorize another execution", c do
    {:ok, receipt} = submit(c)
    {:ok, turn} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
    Repo.delete!(turn)
    assert {:ok, replay} = submit(c)
    assert replay.id == receipt.id
    assert replay.state == "claimed"

    assert {:error, :delivery_claimed} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert Repo.aggregate(Turn, :count) == 0
  end

  test "a queued receipt with a deleted transcript remains a tombstone", c do
    {:ok, receipt} = submit(c)
    Repo.delete!(Repo.get!(Turn, receipt.turn_id))

    assert {:error, :delivery_unavailable} =
             PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)

    assert {:ok, refused} =
             PromptDelivery.refuse(c.user.id, c.conv.id, receipt.id, "delivery_unavailable")

    assert refused.failure_reason == "delivery_unavailable"
    assert {:ok, same} = submit(c)
    assert same.id == receipt.id
    assert Repo.aggregate(Turn, :count) == 0
  end

  test "a claimed receipt cannot be reset or rebound through its changeset", c do
    {:ok, receipt} = submit(c)
    {:ok, _} = PromptDelivery._unsafe_activate(c.conv.id, receipt.id, c.sandbox.id)
    claimed = Repo.reload!(receipt)

    for attrs <- [
          %{state: "queued"},
          %{turn_id: Ecto.UUID.generate()},
          %{sandbox_id: Ecto.UUID.generate()},
          %{payload_hash: <<0::256>>},
          %{delivery_deadline_at: DateTime.add(DateTime.utc_now(), 3600)}
        ] do
      refute PromptReceipt.changeset(claimed, attrs).valid?
    end
  end
end
