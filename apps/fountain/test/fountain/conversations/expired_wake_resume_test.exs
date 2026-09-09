defmodule Fountain.Conversations.ExpiredWakeResumeTest do
  use Fountain.ConversationServerCase
  alias Fountain.Conversations.{PromptDelivery, PromptWakeRequest}
  alias Fountain.Workers.PromptDispatch

  test "a wake whose probe outlives acceptance cannot resume compute after receipt expiry" do
    previous = Application.fetch_env(:fountain, :prompt_delivery_timeout_ms)
    Application.put_env(:fountain, :prompt_delivery_timeout_ms, 400)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :prompt_delivery_timeout_ms, value)
        :error -> Application.delete_env(:fountain, :prompt_delivery_timeout_ms)
      end
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "suspended")

    parent =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox: sandbox,
        runtime: agent.runtime,
        status: "idle"
      )

    stub(ConversationServer, :whereis, fn _ -> nil end)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :get, fn _ ->
      send(owner, {:probe_waiting, self()})
      receive do: (:release_probe -> {:ok, %{status: :running, raw: %{}}})
    end)

    stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
      send(owner, :resumed_after_expiry)
      {:ok, handle}
    end)

    reject(Horde.DynamicSupervisor, :start_child, 2)

    caller =
      spawn(fn ->
        send(owner, {:wake_result, PromptDelivery.accept(user.id, parent.id, "Review", [])})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:probe_waiting, provider_task}, 2_000
    receipt = PromptDelivery.queued(user.id, parent.id)
    [job] = all_enqueued(worker: PromptDispatch)
    assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"

    Process.sleep(
      max(DateTime.diff(receipt.delivery_deadline_at, DateTime.utc_now(), :millisecond), 0) + 20
    )

    assert :ok = perform_job(PromptDispatch, job.args)
    assert Repo.reload!(receipt).state == "refused"
    send(provider_task, :release_probe)
    assert_receive {:wake_result, {:ok, _}}, 2_000
    refute_received :resumed_after_expiry
    assert Repo.reload!(sandbox).status == "suspended"
  end

  test "accepted prompt identity reaches the committed resume before provider I/O" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "suspended")

    parent =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox: sandbox,
        runtime: agent.runtime,
        status: "idle"
      )

    stub(ConversationServer, :whereis, fn _ -> nil end)
    stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :suspended, raw: %{}}} end)

    expect(Managoat.Sandbox.Sprites, :resume, fn handle ->
      refute Repo.in_transaction?()
      operation = Repo.one!(Fountain.Conversations.SandboxOperation)
      receipt = PromptDelivery.queued(user.id, parent.id)
      assert operation.wake_receipt_id == receipt.id
      assert operation.wake_request_id == receipt.id
      assert DateTime.compare(operation.wake_deadline_at, receipt.delivery_deadline_at) != :gt
      assert Repo.get!(PromptWakeRequest, receipt.id).state == "started"
      assert operation.holds_slot
      {:ok, handle}
    end)

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:error, :local_proof_no_actor} end)
    assert {:ok, _} = PromptDelivery.accept(user.id, parent.id, "Review", [])
    assert Repo.reload!(sandbox).status == "ready"
    assert Repo.one!(Fountain.Conversations.SandboxOperation).state == "confirmed"
  end
end
