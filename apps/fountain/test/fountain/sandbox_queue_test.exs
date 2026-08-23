defmodule Fountain.SandboxQueueTest do
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query, only: [from: 2]

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

  defp fill_cap(user) do
    limit = Fountain.Quotas.default_limit()
    for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")
    limit
  end

  defp inert_start_child do
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
  end

  describe "enqueue/2" do
    test "queues a request and reports its position" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      first = enqueue!(user, agent)
      second = enqueue!(user, agent)

      assert first.status == "queued"
      assert SandboxQueue.position(first) == 1
      assert SandboxQueue.position(second) == 2
      assert [%{id: a}, %{id: b}] = SandboxQueue.list_queued(user.id)
      assert {a, b} == {first.id, second.id}
    end

    test "refuses past the depth bound with :queue_full" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      Application.put_env(:fountain, :sandbox_queue_max_depth, 2)
      on_exit(fn -> Application.delete_env(:fountain, :sandbox_queue_max_depth) end)

      enqueue!(user, agent)
      enqueue!(user, agent)

      assert {:error, :queue_full} =
               SandboxQueue.enqueue(%{
                 user_id: user.id,
                 agent_id: agent.id,
                 kind: "start",
                 attrs: %{}
               })
    end

    test "deduplicates schedule_run requests per schedule" do
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

      {:ok, again} =
        SandboxQueue.enqueue(%{
          user_id: user.id,
          agent_id: agent.id,
          kind: "schedule_run",
          schedule_id: schedule_id
        })

      assert again.id == first.id
      assert [_] = SandboxQueue.list_queued(user.id)
    end
  end

  describe "cancel_request/2" do
    test "cancels a queued request" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      assert {:ok, %{status: "cancelled"}} = SandboxQueue.cancel_request(request)
      assert SandboxQueue.list_queued(user.id) == []
      assert SandboxQueue.position(Repo.get!(Request, request.id)) == nil
    end
  end

  describe "get_request/2 and list_queued/1 scoping" do
    test "another tenant sees nothing" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      assert SandboxQueue.get_request(request.id, other.id) == nil
      assert SandboxQueue.list_queued(other.id) == []
    end
  end

  describe "drain/1" do
    test "starts queued requests oldest-first and links the conversation" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)
      inert_start_child()

      assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(user.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "started"
      assert reloaded.conversation_id
      conv = Fountain.Conversations.get_conversation(reloaded.conversation_id, user.id)
      assert conv.agent_id == agent.id
    end

    test "stops at the quota and leaves the rest queued" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_cap(user)
      request = enqueue!(user, agent)

      assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "queued"
    end

    test "deleting the agent takes its queued requests with it" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      {:ok, _} = Fountain.Agents.delete_agent(agent)

      assert Repo.get(Request, request.id) == nil
    end

    test "a broken request is failed and skipped, not head-of-line blocking" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      # Oldest first: a schedule_run whose schedule never existed fails,
      # and the start behind it still gets the slot in the same drain.
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

    test "expires requests queued past the wait bound" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      stale = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [inserted_at: stale]
        )

      assert %{started: 0, failed: 0, expired: 1} = SandboxQueue.drain(user.id)
      assert Repo.get!(Request, request.id).status == "expired"
    end

    test "a schedule_run whose schedule was deleted is failed, not retried forever" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      {:ok, request} =
        SandboxQueue.enqueue(%{
          user_id: user.id,
          agent_id: agent.id,
          kind: "schedule_run",
          schedule_id: Ecto.UUID.generate()
        })

      assert %{started: 0, failed: 1, expired: 0} = SandboxQueue.drain(user.id)
      assert %{status: "failed", error: "schedule_deleted"} = Repo.get!(Request, request.id)
    end
  end

  describe "the poke in update_sandbox/2" do
    test "a slot-freeing transition enqueues a drain job for the owner" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "terminated"})

      assert_enqueued(
        worker: Fountain.Workers.SandboxQueueDrainer,
        args: %{user_id: user.id}
      )
    end

    test "a transition that frees nothing pokes nothing" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "ready"})

      refute_enqueued(worker: Fountain.Workers.SandboxQueueDrainer)
    end
  end
end
