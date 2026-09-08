defmodule Fountain.Conversations.ActorStartupRecoveryTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{
    ActorClaim,
    ActorLaunches,
    ActorOwnership,
    ActorStartup,
    ActorStartups,
    ExecutionDeadlineWorker,
    LogEvent
  }

  defp fixture(offset \\ -1) do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    parent = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    id = Ecto.UUID.generate()
    {:ok, claim} = ActorOwnership.claim(user.id, parent.id, sandbox.id, id)

    startup =
      Repo.insert!(%ActorStartup{
        id: id,
        actor_claim_id: id,
        user_id: user.id,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        deadline_at: DateTime.add(DateTime.utc_now(), offset)
      })

    %{user: user, sandbox: sandbox, parent: parent, claim: claim, startup: startup}
  end

  defp coordinator(id, opts \\ []) do
    start_supervised!(%{
      id: id,
      start:
        {ExecutionDeadlineWorker, :start_link,
         [
           Keyword.merge(
             [
               name: nil,
               interval_ms: 20,
               terminator: fn _ -> flunk("unexpected provider call") end
             ],
             opts
           )
         ]}
    })
  end

  defp expired(id, attempts \\ 100)
  defp expired(_id, 0), do: flunk("saved startup never expired")

  defp expired(id, attempts) do
    case Repo.get!(ActorStartup, id) do
      %{state: "expired"} = row ->
        row

      _ ->
        Process.sleep(20)
        expired(id, attempts - 1)
    end
  end

  test "startup expiry survives actor loss and coordinator restart" do
    previous = Application.fetch_env(:fountain, :provision_deadline_ms)
    Application.put_env(:fountain, :provision_deadline_ms, 400)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :provision_deadline_ms, value)
        :error -> Application.delete_env(:fountain, :provision_deadline_ms)
      end
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    parent =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox: sandbox,
        runtime: agent.runtime,
        status: "idle"
      )

    {:ok, {_, launch}} = ActorLaunches.reconnect(parent, sandbox)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :get, fn _ ->
      send(owner, :provider_blocked)
      Process.sleep(:infinity)
    end)

    coordinator(:before_loss)

    {:ok, pid} =
      GenServer.start(ConversationServer,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        launch_id: launch.id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive :provider_blocked, 5_000
    startup = Repo.one!(from s in ActorStartup, where: s.conversation_id == ^parent.id)
    assert :ok = stop_supervised(:before_loss)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    Process.sleep(
      max(DateTime.diff(startup.deadline_at, DateTime.utc_now(), :millisecond), 0) + 20
    )

    assert Repo.reload!(startup).state == "starting"
    coordinator(:after_loss)
    saved = expired(startup.id)
    assert saved.deadline_at == startup.deadline_at
    assert Repo.get!(ActorClaim, startup.actor_claim_id).state == "active"
    assert Repo.reload!(sandbox).status == "ready"
    refute ActorStartups.writable?(startup.actor_claim_id)
  end

  test "concurrent coordinators expire once and retain provider uncertainty" do
    c = fixture()
    {:ok, {key, _}} = Fountain.Accounts.create_api_key(c.user.id, "startup recovery")
    c.parent |> change(callback_api_key_id: key.id) |> Repo.update!()

    operation =
      Repo.insert!(%Conversations.SandboxOperation{
        sandbox_id: c.sandbox.id,
        user_id: c.user.id,
        provider: c.sandbox.provider,
        sandbox_name: c.sandbox.sprite_name,
        action: "create",
        state: "uncertain",
        holds_slot: true,
        submitted_at: DateTime.utc_now()
      })

    coordinator(:first)
    coordinator(:second)
    saved = expired(c.startup.id)
    assert Repo.reload!(key).revoked_at
    assert Repo.reload!(operation) == operation
    assert Repo.reload!(c.claim).state == "active"
    assert saved.deadline_at == c.startup.deadline_at
    assert Repo.aggregate(LogEvent, :count) == 1
    assert {:ok, :expired} = ActorStartups._unsafe_recover(c.startup.id)
    assert Repo.aggregate(LogEvent, :count) == 1
  end

  test "due pages exclude future and foreign bindings and preserve a stable cursor" do
    due = for _ <- 1..4, do: fixture()
    future = fixture(60)
    foreign = fixture()
    foreign.parent |> change(user_id: future.user.id) |> Repo.update!()
    settled = fixture(60)

    assert :ok =
             ActorStartups.complete(%{
               actor_claim: settled.claim.id,
               user_id: settled.user.id,
               conversation_id: settled.parent.id,
               sandbox_id: settled.sandbox.id
             })

    ids = due |> Enum.map(& &1.startup.id) |> Enum.sort()
    now = DateTime.utc_now()
    assert Enum.take(ids, 2) == ActorStartups._unsafe_due(now, 2)
    assert Enum.drop(ids, 2) == ActorStartups._unsafe_due(now, 2, Enum.at(ids, 1))
    assert [] == ActorStartups._unsafe_due(now, 2, List.last(ids))
    assert {:ok, :stale} = ActorStartups._unsafe_recover(foreign.startup.id)
    assert Repo.reload!(foreign.startup).state == "starting"
    assert {:error, :deadline_not_reached} = ActorStartups._unsafe_recover(future.startup.id)
    assert {:ok, :stale} = ActorStartups._unsafe_recover(Ecto.UUID.generate())
  end

  test "recovery rechecks ownership after the candidate scan" do
    c = fixture()
    assert [id] = ActorStartups._unsafe_due(DateTime.utc_now(), 10)
    c.claim |> change(state: "superseded") |> Repo.update!()
    assert {:ok, :stale} = ActorStartups._unsafe_recover(id)
    assert Repo.reload!(c.startup).state == "starting"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "failed expiry is retryable after restart without changing the saved deadline" do
    c = fixture()

    {:ok, _} =
      Fountain.Webhooks.create_endpoint(
        c.user.id,
        %{
          "url" => "https://example.test/recovery",
          "event_types" => ["conversation.reattach.failed"]
        }
      )

    owner = self()

    stub(Fountain.Workers.WebhookDelivery, :enqueue, fn _, _ ->
      send(owner, :enqueue_failed)
      {:error, :unavailable}
    end)

    coordinator(:failed_expiry, interval_ms: 10_000)
    assert_receive :enqueue_failed, 2_000
    assert :ok = stop_supervised(:failed_expiry)
    assert Repo.reload!(c.startup).state == "starting"
    assert Repo.aggregate(LogEvent, :count) == 0

    stub(Fountain.Workers.WebhookDelivery, :enqueue, fn endpoint, event ->
      Mimic.call_original(Fountain.Workers.WebhookDelivery, :enqueue, [endpoint, event])
    end)

    coordinator(:retry_expiry)
    saved = expired(c.startup.id)
    assert saved.deadline_at == c.startup.deadline_at
    assert Repo.aggregate(LogEvent, :count) == 1
    assert_enqueued(worker: Fountain.Workers.WebhookDelivery)
  end
end
