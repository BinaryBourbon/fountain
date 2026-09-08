defmodule Fountain.Conversations.CreationHandoffTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{ActorLaunch, Conversation, PromptDelivery, PromptReceipt, Sandbox}
  alias Fountain.Workers.ActorLaunchDispatch

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    %{user: user, agent: agent}
  end

  defp start(c) do
    Conversations.start_conversation(%{
      "user_id" => c.user.id,
      "agent_id" => c.agent.id,
      "prompt" => "Review opening change"
    })
  end

  defp kill_caller(caller) do
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
  end

  test "creator death cannot leave a reserved parent without its opening prompt", c do
    owner = self()

    stub(Fountain.Audit, :record, fn attrs ->
      if attrs.action == "conversation.created" do
        send(owner, {:before_opening_prompt, self()})
        receive do: (:continue -> :ok)
      else
        Mimic.call_original(Fountain.Audit, :record, [attrs])
      end
    end)

    reject(Horde.DynamicSupervisor, :start_child, 2)
    caller = spawn(fn -> start(c) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:before_opening_prompt, ^caller}, 5_000
    kill_caller(caller)

    saved =
      {Repo.aggregate(Sandbox, :count), Repo.aggregate(Conversation, :count),
       Repo.aggregate(PromptReceipt, :count), Repo.aggregate(ActorLaunch, :count)}

    assert saved in [{0, 0, 0, 0}, {1, 1, 1, 1}]
  end

  test "a creator lost before Horde leaves a durable way to start its saved prompt", c do
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      send(owner, {:before_launch, self(), args})
      receive do: (:continue -> {:ok, self()})
    end)

    caller = spawn(fn -> start(c) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:before_launch, ^caller, args}, 5_000
    receipt = PromptDelivery.queued(c.user.id, args[:conversation_id])
    assert receipt
    [job] = all_enqueued(worker: ActorLaunchDispatch)
    kill_caller(caller)
    stub(ConversationServer, :whereis, fn _ -> nil end)

    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, retry_args} ->
      assert retry_args[:conversation_id] == args[:conversation_id]
      assert retry_args[:sandbox_id] == args[:sandbox_id]
      send(owner, :saved_launch_started)
      {:ok, self()}
    end)

    assert {:snooze, 15} = perform_job(ActorLaunchDispatch, job.args)
    assert_receive :saved_launch_started
  end
end
