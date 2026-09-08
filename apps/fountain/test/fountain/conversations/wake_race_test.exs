defmodule Fountain.Conversations.WakeRaceTest do
  @moduledoc "Database replacement ownership survives Horde duplicates and startup failure."
  use Fountain.DataCase, async: false

  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    old_sandbox = insert_sandbox(user_id: user.id, status: "terminated")

    conv =
      insert_conversation(
        user_id: user.id,
        agent_id: agent.id,
        sandbox_id: old_sandbox.id,
        status: "idle"
      )

    {:ok, user: user, agent: agent, conv: conv, old_sandbox: old_sandbox}
  end

  defp sandbox_of(conv_id) do
    conv_id |> Conversations._unsafe_get_conversation!() |> Fountain.Repo.preload(:sandbox)
  end

  defp sandbox_ids do
    Fountain.Conversations.Sandbox |> Fountain.Repo.all() |> MapSet.new(& &1.id)
  end

  # Only the rows this wake created — the factory makes its own, and counting
  # those was how the first version of this test failed against a working fix.
  defp sandboxes_created_since(before) do
    Fountain.Conversations.Sandbox
    |> Fountain.Repo.all()
    |> Enum.reject(&MapSet.member?(before, &1.id))
  end

  describe "when the wake wins the race" do
    test "the conversation points at the new sandbox", %{conv: conv, old_sandbox: old} do
      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      stub(ConversationServer, :queue_prompt_receipt, fn _pid, _prompt -> :ok end)

      {:ok, _} = Conversations.wake_conversation(conv.id, "hello")

      woken = sandbox_of(conv.id)
      refute woken.sandbox_id == old.id, "the row still names the retired sandbox"
      assert woken.sandbox.status != "terminated", "the row names a terminated sandbox"
    end
  end

  describe "when Horde reports an existing actor" do
    setup do
      winner = spawn(fn -> Process.sleep(:infinity) end)

      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
        {:error, {:already_started, winner}}
      end)

      stub(ConversationServer, :queue_prompt_receipt, fn _pid, _prompt -> :ok end)

      {:ok, winner: winner}
    end

    test "the database binding is retained until the launch is acknowledged", %{
      conv: conv,
      old_sandbox: old
    } do
      {:ok, _} = Conversations.wake_conversation(conv.id, "hello")
      parent = sandbox_of(conv.id)
      refute parent.sandbox_id == old.id
      launch = Repo.get_by!(Conversations.ActorLaunch, sandbox_id: parent.sandbox_id)
      assert launch.source_sandbox_id == old.id
      assert launch.state == "requested"
      assert parent.sandbox.status == "pending"
    end

    test "the one saved reservation remains available to its durable launch", %{
      conv: conv
    } do
      before = sandbox_ids()

      {:ok, _} = Conversations.wake_conversation(conv.id, "hello")

      created = sandboxes_created_since(before)
      assert [sandbox] = created
      assert sandbox.status == "pending"
      assert sandbox_of(conv.id).sandbox_id == sandbox.id
      assert Repo.get_by!(Conversations.ActorLaunch, sandbox_id: sandbox.id).state == "requested"
      assert length(all_enqueued(worker: Fountain.Workers.ActorLaunchDispatch)) == 1
    end

    test "the prompt is handed to the winner", %{conv: conv, winner: winner} do
      test_pid = self()

      stub(ConversationServer, :queue_prompt_receipt, fn pid, prompt ->
        send(test_pid, {:queued, pid, prompt})
        :ok
      end)

      {:ok, _} = Conversations.wake_conversation(conv.id, "hello")

      assert_receive {:queued, ^winner, receipt_id}
      receipt = Repo.get!(Conversations.PromptReceipt, receipt_id)
      assert Repo.get!(Conversations.Turn, receipt.turn_id).prompt == "hello"
    end
  end

  describe "when the start fails outright" do
    test "the unused sandbox does not keep a quota slot", %{conv: conv} do
      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec -> {:error, :boom} end)

      before = sandbox_ids()

      assert {:error, :boom} = Conversations.wake_conversation(conv.id)

      for sandbox <- sandboxes_created_since(before) do
        assert sandbox.status == "failed"
        assert sandbox.status not in Fountain.Quotas.active_statuses()
        launch = Repo.get_by!(Conversations.ActorLaunch, sandbox_id: sandbox.id)
        assert launch.state == "refused"
        assert launch.failure_reason == "start_failed"
      end
    end
  end
end
