defmodule Fountain.Workers.SandboxQueueDrainerTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.SandboxQueue
  alias Fountain.SandboxQueue.Request
  alias Fountain.Workers.SandboxQueueDrainer

  defp enqueue!(user, agent) do
    {:ok, request} =
      SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{"prompt" => "hi"}
      })

    request
  end

  test "a per-user job drains that user's queue" do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)
    request = enqueue!(user, agent)
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    assert :ok = perform_job(SandboxQueueDrainer, %{"user_id" => user.id})

    assert Repo.get!(Request, request.id).status == "started"
  end

  test "the cron firing (empty args) re-pokes every tenant with anything queued" do
    user_a = insert_active_user()
    user_b = insert_active_user()
    agent_a = insert_agent(user_id: user_a.id)
    agent_b = insert_agent(user_id: user_b.id)
    enqueue!(user_a, agent_a)
    enqueue!(user_b, agent_b)

    assert :ok = perform_job(SandboxQueueDrainer, %{})

    assert_enqueued(worker: SandboxQueueDrainer, args: %{user_id: user_a.id})
    assert_enqueued(worker: SandboxQueueDrainer, args: %{user_id: user_b.id})
  end

  test "the cron firing does nothing when nothing is queued" do
    assert :ok = perform_job(SandboxQueueDrainer, %{})
    refute_enqueued(worker: SandboxQueueDrainer)
  end
end
