defmodule Fountain.Conversations.InitialPromptReceiptTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations

  alias Fountain.Conversations.{
    ConversationServer,
    LogEvent,
    PromptDelivery,
    PromptReceipt,
    Sandbox,
    Turn,
    TurnImage
  }

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    %{user: user, agent: agent}
  end

  defp start(c, attrs \\ %{}) do
    Conversations.start_conversation(
      Map.merge(
        %{
          "user_id" => c.user.id,
          "agent_id" => c.agent.id,
          "prompt" => "Review opening change"
        },
        attrs
      )
    )
  end

  test "opening text and images are saved before Horde can start a worker", c do
    image = %{media_type: "image/png", data: <<0, 1, 2>>}

    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      receipt = PromptDelivery.queued(c.user.id, args[:conversation_id])
      assert receipt
      assert Repo.get!(Turn, receipt.turn_id).status == "pending"
      assert Repo.one!(TurnImage).data == image.data
      refute Keyword.has_key?(args, :initial_prompt)
      refute Keyword.has_key?(args, :receipt_id)
      {:ok, self()}
    end)

    assert {:ok, conv} = start(c, %{"images" => [image]})
    receipt = PromptDelivery.queued(c.user.id, conv.id)
    id = receipt.id
    assert_receive {:"$gen_cast", {:prompt_receipt, ^id}}
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "a failed actor start retains the opening prompt with an explicit outcome", c do
    expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:error, :max_children} end)
    assert {:ok, conv} = start(c)
    assert conv.status == "failed"
    receipt = Repo.one!(PromptReceipt)
    assert receipt.state == "refused"
    assert receipt.failure_reason == "provisioning_failed"
    assert Repo.get!(Turn, receipt.turn_id).status == "failed"
    assert Repo.get!(Sandbox, conv.sandbox_id).status == "failed"
    assert Repo.aggregate(LogEvent, :count) == 2
    assert length(all_enqueued(worker: Fountain.Workers.TurnDeadlineNotification)) == 2
  end

  test "an old launch failure cannot fail a replacement binding or its prompt", c do
    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      conv = Conversations.get_conversation(args[:conversation_id], c.user.id)
      original = Conversations.get_sandbox(args[:sandbox_id], c.user.id)

      replacement =
        insert_sandbox(
          user_id: c.user.id,
          status: "ready",
          agent_id: original.agent_id,
          environment_id: original.environment_id,
          vault_id: original.vault_id,
          mode: original.mode
        )

      {:ok, _} =
        Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "idle"})

      {:error, :max_children}
    end)

    assert {:ok, conv} = start(c)
    assert conv.status == "idle"
    assert PromptDelivery.queued(c.user.id, conv.id)
    assert Repo.get!(Sandbox, conv.sandbox_id).status == "ready"
    assert Repo.aggregate(LogEvent, :count) == 0
  end

  test "opening a worker inside an outer transaction is refused before reservation", c do
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert {:ok, {:error, :provider_transaction_open}} = Repo.transaction(fn -> start(c) end)
    assert Repo.aggregate(Sandbox, :count) == 0
    assert Repo.aggregate(PromptReceipt, :count) == 0
  end

  test "invalid opening input is refused before any machine is reserved", c do
    reject(Horde.DynamicSupervisor, :start_child, 2)
    assert {:error, :invalid_prompt} = start(c, %{"prompt" => " "})

    assert {:error, :invalid_prompt} =
             start(c, %{"prompt" => nil, "images" => [%{media_type: "image/png", data: <<1>>}]})

    assert Repo.aggregate(Sandbox, :count) == 0
    assert Repo.aggregate(PromptReceipt, :count) == 0
  end
end
