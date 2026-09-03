defmodule Fountain.Workers.SandboxQueueDrainerTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.SandboxQueue
  alias Fountain.SandboxQueue.Request
  alias Fountain.Workers.SandboxQueueDrainer

  test "a tenant job drains that tenant's queue" do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)

    {:ok, request} =
      SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{"prompt" => "hi"}
      })

    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    assert :ok = perform_job(SandboxQueueDrainer, %{"user_id" => user.id})
    assert Repo.get!(Request, request.id).status == "started"
  end

  test "the cron backstop pokes every active tenant" do
    users = for _ <- 1..2, do: insert_active_user()

    for user <- users do
      agent = insert_agent(user_id: user.id)

      {:ok, _} =
        SandboxQueue.enqueue(%{
          user_id: user.id,
          agent_id: agent.id,
          kind: "start",
          attrs: %{}
        })
    end

    assert :ok = perform_job(SandboxQueueDrainer, %{})

    for user <- users do
      assert_enqueued(worker: SandboxQueueDrainer, args: %{user_id: user.id})
    end
  end
end
