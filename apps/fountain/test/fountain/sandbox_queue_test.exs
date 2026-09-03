defmodule Fountain.SandboxQueueTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.SandboxQueue
  alias Fountain.SandboxQueue.Request

  defp enqueue!(user, agent, extra \\ %{}) do
    {:ok, request} =
      SandboxQueue.enqueue(
        Map.merge(
          %{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{"prompt" => "hi"}},
          extra
        )
      )

    request
  end

  defp fill_tenant_cap(user) do
    limit = Fountain.Quotas.sandbox_limit(user.id)
    for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")
  end

  defp fill_fleet do
    user = insert_verified_user(sandbox_limit_override: 20)
    limit = Fountain.Quotas.settings().fleet_ceiling
    for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")
  end

  defp inert_start_child do
    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "enqueue/2" do
    test "orders requests and reports their positions" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      first = enqueue!(user, agent)
      second = enqueue!(user, agent)

      assert SandboxQueue.position(first) == 1
      assert SandboxQueue.position(second) == 2
      assert Enum.map(SandboxQueue.list_queued(user.id), & &1.id) == [first.id, second.id]
    end

    test "refuses work beyond the default depth bound" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      for _ <- 1..10, do: enqueue!(user, agent)

      assert {:error, :queue_full} =
               SandboxQueue.enqueue(%{
                 user_id: user.id,
                 agent_id: agent.id,
                 kind: "start",
                 attrs: %{}
               })
    end

    test "deduplicates a scheduled run even when the queue is full" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      schedule_id = Ecto.UUID.generate()

      {:ok, first} =
        SandboxQueue.enqueue(%{
          user_id: user.id,
          agent_id: agent.id,
          kind: "schedule_run",
          schedule_id: schedule_id
        })

      for _ <- 1..9, do: enqueue!(user, agent)

      assert {:ok, again} =
               SandboxQueue.enqueue(%{
                 user_id: user.id,
                 agent_id: agent.id,
                 kind: "schedule_run",
                 schedule_id: schedule_id
               })

      assert again.id == first.id
    end
  end

  test "reads are tenant-scoped" do
    user = insert_verified_user()
    other = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    request = enqueue!(user, agent)

    assert SandboxQueue.get_request(request.id, other.id) == nil
    assert SandboxQueue.list_queued(other.id) == []
  end

  test "cancellation is a compare-and-swap and erases the prompt" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    request = enqueue!(user, agent)

    assert {:ok, cancelled} = SandboxQueue.cancel_request(request)
    assert cancelled.status == "cancelled"
    assert cancelled.attrs == %{}
    assert {:error, :not_found} = SandboxQueue.cancel_request(request)
  end

  describe "drain/1" do
    test "starts work, links the conversation and erases queued attributes" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "started"
      assert reloaded.attrs == %{}
      assert Fountain.Conversations.get_conversation(reloaded.conversation_id, user.id)
    end

    test "leaves a request waiting at the tenant cap" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_tenant_cap(user)
      request = enqueue!(user, agent)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "queued"
    end

    test "leaves a request waiting at the fleet ceiling" do
      fill_fleet()
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "queued"
    end

    test "a request that loses funding fails terminally and erases its prompt" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      {:ok, _} =
        Fountain.Credits.debit(
          user.id,
          Fountain.Credits.balance(user.id) + 1,
          "burn_turn",
          idempotency_key: "queue-#{request.id}"
        )

      assert %{started: 0, failed: 1, expired: 0} = SandboxQueue.drain(user.id)

      assert %{status: "failed", error: "insufficient_credits", attrs: %{}} =
               Repo.get!(Request, request.id)
    end

    test "fails broken work without head-of-line blocking the next request" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      {:ok, broken} =
        SandboxQueue.enqueue(%{
          user_id: user.id,
          agent_id: agent.id,
          kind: "schedule_run",
          schedule_id: Ecto.UUID.generate()
        })

      alive = enqueue!(user, agent)

      assert %{started: 1, failed: 1, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, broken.id).status == "failed"
      assert Repo.get!(Request, alive.id).status == "started"
    end

    test "expires overdue work and erases its prompt" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      stale = DateTime.utc_now() |> DateTime.add(-2, :hour)

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id), set: [inserted_at: stale])

      assert %{started: 0, failed: 0, expired: 1} = SandboxQueue.drain(user.id)
      assert %{status: "expired", attrs: %{}} = Repo.get!(Request, request.id)
    end

    test "recovers a stale claim left by a dead worker" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()
      stale = DateTime.utc_now() |> DateTime.add(-10, :minute)

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [status: "starting", updated_at: stale]
        )

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "started"
    end
  end

  test "a slot-freeing transition pokes every tenant with queued work" do
    owner = insert_verified_user()
    waiting = insert_verified_user()
    agent = insert_agent(user_id: waiting.id)
    enqueue!(waiting, agent)
    sandbox = insert_sandbox(user_id: owner.id, status: "ready")

    {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "terminated"})

    assert_enqueued(worker: Fountain.Workers.SandboxQueueDrainer, args: %{user_id: waiting.id})
  end
end
