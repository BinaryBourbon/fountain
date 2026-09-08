defmodule Fountain.Conversations.ProvisionContextTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Broker.Native
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Conversations
  alias Fountain.Conversations.{LogEvent, PromptDelivery, ProvisionContext, Turn}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "starting")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "pending")
    context = ProvisionContext.new(conv, sandbox)
    %{user: user, sandbox: sandbox, conv: conv, context: context}
  end

  defp session(c) do
    {:ok, session} = Native.prepare(c.conv.id, %{}, %{}, user_id: c.user.id)
    session
  end

  test "broker mint uses the saved tenant and commits its stages with the token", c do
    expect(Fountain.Broker, :prepare, fn id, brokered, bindings, opts ->
      assert id == c.conv.id
      assert opts[:user_id] == c.user.id
      Native.prepare(id, brokered, bindings, opts)
    end)

    assert {:ok, session} =
             Conversations.Egress.prepare(c.conv.id, %{}, %{},
               user_id: Ecto.UUID.generate(),
               provision_context: c.context
             )

    assert {:ok, _} = Sessions.lookup(session.token)
    assert Repo.aggregate(LogEvent, :count) == 2
    assert length(all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)) == 2
  end

  test "a failed broker stage enqueue rolls back the minted token", c do
    {:ok, _} =
      Fountain.Webhooks.create_endpoint(c.user.id, %{
        "url" => "https://example.test/hook",
        "event_types" => ["conversation.broker.done"]
      })

    expect(Fountain.Broker, :prepare, fn id, brokered, bindings, opts ->
      Native.prepare(id, brokered, bindings, opts)
    end)

    expect(Fountain.Workers.WebhookDelivery, :enqueue, fn _, _ -> {:error, :unavailable} end)

    assert_raise MatchError, fn ->
      Conversations.Egress.prepare(c.conv.id, %{}, %{}, provision_context: c.context)
    end

    assert Repo.aggregate(Fountain.Broker.Native.Session, :count) == 0
    assert Repo.aggregate(LogEvent, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification) == []
  end

  test "a moved binding cannot mint another broker session", c do
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")
    {:ok, _} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})

    reject(&Fountain.Broker.prepare/4)

    assert {:error, :ownership_changed} =
             Conversations.Egress.prepare(c.conv.id, %{}, %{}, provision_context: c.context)

    assert Repo.aggregate(Fountain.Broker.Native.Session, :count) == 0
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "failure settles opening intent and revokes only this worker's session", c do
    original = session(c)
    replacement = session(c)
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.conv.id, "Review", [])

    assert {:ok, %{cleanup?: true}} =
             ProvisionContext.fail(c.context, %{reason: "setup failed"}, original)

    assert Repo.reload!(c.conv).status == "failed"
    assert Repo.reload!(c.sandbox).status == "failed"
    assert Repo.reload!(receipt).failure_reason == "provisioning_failed"
    assert Repo.get!(Turn, receipt.turn_id).status == "failed"
    assert Sessions.lookup(original.token) == :error
    assert {:ok, _} = Sessions.lookup(replacement.token)
    assert Repo.aggregate(LogEvent, :count) == 2
    assert length(all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)) == 2

    assert {:error, :ownership_changed} =
             ProvisionContext.fail(c.context, %{reason: "duplicate"}, original)

    assert Repo.aggregate(LogEvent, :count) == 2
  end

  test "notification failure after commit preserves the cleanup decision and durable job", c do
    original = session(c)

    expect(Conversations, :_unsafe_notify_stage, fn _ ->
      raise "local notification unavailable"
    end)

    assert {:ok, %{cleanup?: true}} =
             ProvisionContext.fail(c.context, %{reason: "setup failed"}, original)

    assert Repo.reload!(c.conv).status == "failed"
    assert Repo.reload!(c.sandbox).status == "failed"
    assert Sessions.lookup(original.token) == :error
    assert length(all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)) == 1
  end

  test "failed delivery enqueue rolls back failure, prompt refusal and session revocation", c do
    original = session(c)
    {:ok, receipt} = PromptDelivery.submit(c.user.id, c.conv.id, "Review", [])

    {:ok, _} =
      Fountain.Webhooks.create_endpoint(c.user.id, %{"url" => "https://example.test/hook"})

    expect(Fountain.Workers.WebhookDelivery, :enqueue, fn _, _ -> {:error, :unavailable} end)

    assert {:error, :decision_unavailable} =
             ProvisionContext.fail(c.context, %{reason: "setup failed"}, original)

    assert Repo.reload!(c.conv).status == "pending"
    assert Repo.reload!(c.sandbox).status == "starting"
    assert Repo.reload!(receipt).state == "queued"
    assert Repo.get!(Turn, receipt.turn_id).status == "pending"
    assert {:ok, _} = Sessions.lookup(original.token)
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "a moved binding rejects late stage, output and failure", c do
    replacement = insert_sandbox(user_id: c.user.id, status: "ready")
    {:ok, moved} = Conversations.update_conversation(c.conv, %{sandbox_id: replacement.id})
    {:ok, receipt} = PromptDelivery.submit(c.user.id, moved.id, "new request", [])

    assert ProvisionContext.stage(c.context, "setup", "failed", %{reason: "late"}) == nil
    assert ProvisionContext.output(c.context, "setup", "late output") == nil
    assert {:error, :ownership_changed} = ProvisionContext.fail(c.context, %{reason: "late"})
    assert Repo.reload!(receipt).state == "queued"
    assert Repo.reload!(replacement).status == "ready"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "another tenant cannot publish through a forged provisioning context", c do
    context = %{c.context | user_id: insert_verified_user().id}
    assert ProvisionContext.stage(context, "setup", "done") == nil
    assert ProvisionContext.output(context, "setup", "output") == nil
    assert {:error, :ownership_changed} = ProvisionContext.fail(context, %{reason: "failed"})
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "rolled-back stage publication sends no event and leaves no notification job", c do
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{c.conv.id}")

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert %LogEvent{} = ProvisionContext.stage(c.context, "setup", "done")
               Repo.rollback(:abort)
             end)

    refute_received {:log_event, _}
    assert Repo.aggregate(LogEvent, :count) == 0
    assert all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification) == []
  end

  test "reattach failure leaves a ready machine and its cotenant's turn intact", c do
    {:ok, sandbox} = Conversations.update_sandbox(c.sandbox, %{status: "ready"})
    peer = insert_conversation(user_id: c.user.id, sandbox: sandbox)
    turn = insert_turn(peer, status: "running")
    context = ProvisionContext.new(c.conv, sandbox)

    assert {:ok, %{cleanup?: false}} = ProvisionContext.fail(context, %{reason: "missing keys"})
    assert Repo.reload!(c.conv).status == "failed"
    assert Repo.reload!(sandbox).status == "ready"
    assert Repo.reload!(turn).status == "running"
  end

  test "retirement can settle original pending intent without another cleanup grant", c do
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "terminated"})
    assert {:ok, %{cleanup?: false}} = ProvisionContext.fail(c.context, %{reason: "retired"})
    assert Repo.reload!(c.conv).status == "failed"
    assert Repo.reload!(c.sandbox).status == "terminated"
  end

  test "a reset idle conversation's new intent is not failed by the old context", c do
    {:ok, _} = Conversations.update_sandbox(c.sandbox, %{status: "terminated"})
    {:ok, conv} = Conversations.update_conversation(c.conv, %{status: "idle"})
    {:ok, receipt} = PromptDelivery.submit(c.user.id, conv.id, "new request", [])
    assert {:error, :ownership_changed} = ProvisionContext.fail(c.context, %{reason: "late"})
    assert Repo.reload!(receipt).state == "queued"
    assert Repo.reload!(conv).status == "idle"
  end

  test "one-session revocation requires both the saved tenant and conversation", c do
    original = session(c)
    assert :ok = Sessions.release_session(Ecto.UUID.generate(), c.conv.id, original.token)
    assert :ok = Sessions.release_session(c.user.id, Ecto.UUID.generate(), original.token)
    assert {:ok, _} = Sessions.lookup(original.token)
    assert :ok = Sessions.release_session(c.user.id, c.conv.id, original.token)
    assert Sessions.lookup(original.token) == :error
  end
end
