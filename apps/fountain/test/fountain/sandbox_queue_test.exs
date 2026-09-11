defmodule Fountain.SandboxQueueTest do
  use Fountain.DataCase, async: true

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

  defp enqueued_events(user) do
    user.id
    |> Fountain.Audit.list_recent_for_user(50)
    |> Enum.filter(&(&1.action == "sandbox_request.enqueued"))
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

    test "position counts a request that is already being replayed" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      first = enqueue!(user, agent)
      second = enqueue!(user, agent)

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^first.id), set: [status: "starting"])

      assert SandboxQueue.position(Repo.get!(Request, second.id)) == 2
    end

    test "a request that is no longer waiting has no position" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      request = enqueue!(user, agent)

      assert SandboxQueue.position(%{request | status: "started"}) == nil
    end

    test "refuses work beyond the depth bound" do
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

    test "the depth bound counts claimed rows, not just waiting ones" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      for _ <- 1..10, do: enqueue!(user, agent)

      {10, _} = Repo.update_all(Request, set: [status: "starting"])

      assert {:error, :queue_full} =
               SandboxQueue.enqueue(%{
                 user_id: user.id,
                 agent_id: agent.id,
                 kind: "start",
                 attrs: %{}
               })
    end

    test "the depth bound is per tenant" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      other_agent = insert_agent(user_id: other.id)

      for _ <- 1..10, do: enqueue!(user, agent)

      assert {:ok, _} =
               SandboxQueue.enqueue(%{
                 user_id: other.id,
                 agent_id: other_agent.id,
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

    test "a schedule whose last request already finished queues a fresh one" do
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

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^first.id), set: [status: "started"])

      assert {:ok, second} =
               SandboxQueue.enqueue(%{
                 user_id: user.id,
                 agent_id: agent.id,
                 kind: "schedule_run",
                 schedule_id: schedule_id
               })

      refute second.id == first.id
    end

    test "a deduplicated firing records nothing, because nothing was written" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      schedule_id = Ecto.UUID.generate()

      params = %{
        user_id: user.id,
        agent_id: agent.id,
        kind: "schedule_run",
        schedule_id: schedule_id
      }

      {:ok, _} = SandboxQueue.enqueue(params)
      {:ok, _} = SandboxQueue.enqueue(params)
      {:ok, _} = SandboxQueue.enqueue(params)

      # One row, and one audit event for it. A trail that logged the two
      # firings that wrote nothing would report three enqueues for one request.
      assert enqueued_events(user) |> length() == 1
    end

    test "carries the sandbox restriction the request arrived under" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      key_id = Ecto.UUID.generate()

      request = enqueue!(user, agent, %{sandbox_key_id: key_id})

      # Not a credential — the rule a replay has to be held to (ADR 0045).
      assert Repo.get!(Request, request.id).sandbox_key_id == key_id
    end
  end

  describe "schedule_request/2" do
    test "finds a schedule's live request and stops once it is terminal" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      schedule_id = Ecto.UUID.generate()

      refute SandboxQueue.schedule_request(user.id, schedule_id)

      request =
        enqueue!(user, agent, %{kind: "schedule_run", schedule_id: schedule_id, attrs: %{}})

      assert SandboxQueue.schedule_request(user.id, schedule_id).id == request.id

      {1, _} =
        Repo.update_all(from(r in Request, where: r.id == ^request.id),
          set: [status: "started"]
        )

      refute SandboxQueue.schedule_request(user.id, schedule_id)
    end

    test "does not cross tenant scope" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      schedule_id = Ecto.UUID.generate()

      enqueue!(user, agent, %{kind: "schedule_run", schedule_id: schedule_id, attrs: %{}})

      refute SandboxQueue.schedule_request(other.id, schedule_id)
    end
  end

  test "reads are tenant-scoped" do
    user = insert_verified_user()
    other = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    request = enqueue!(user, agent)

    assert SandboxQueue.get_request(request.id, other.id) == nil
    assert SandboxQueue.list_queued(other.id) == []
    assert SandboxQueue.get_request(request.id, user.id).id == request.id
  end

  test "a malformed id reads as missing rather than raising" do
    user = insert_verified_user()
    assert SandboxQueue.get_request("not-a-uuid", user.id) == nil
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

  test "cancellation refuses a request the drainer already claimed" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    request = enqueue!(user, agent)

    {1, _} =
      Repo.update_all(from(r in Request, where: r.id == ^request.id), set: [status: "starting"])

    # The caller still holds the `queued` struct it fetched a moment ago.
    # Cancelling on that stale read would abandon a start already in flight.
    assert {:error, :not_found} = SandboxQueue.cancel_request(request)
    assert Repo.get!(Request, request.id).status == "starting"
  end
end
