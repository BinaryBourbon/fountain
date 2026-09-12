defmodule Fountain.Conversations.InitialStartFailureTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, Sandbox}

  setup do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, agent: agent}
  end

  test "an unchanged initial start failure retires both pending rows", ctx do
    expect(Fountain.Billing, :record_usage, 2, fn user_id, event, sandbox_id, "sandbox", _ ->
      assert user_id == ctx.user.id
      assert event in ["sandbox_provision_failed", "sandbox_terminated"]
      refute Repo.in_transaction?()
      assert Repo.get!(Sandbox, sandbox_id).status == "failed"

      assert Repo.one!(from c in Conversation, where: c.sandbox_id == ^sandbox_id).status ==
               "failed"

      :ok
    end)

    expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:error, :max_children} end)
    assert {:ok, conv} = start(ctx)
    assert conv.status == "failed"
    sandbox = Repo.get!(Sandbox, conv.sandbox_id)
    assert sandbox.status == "failed"
    assert sandbox.terminated_at
  end

  test "a delayed start error preserves a replacement binding and both machines", ctx do
    test = self()

    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      conv = Repo.get!(Conversation, args[:conversation_id])
      original = Repo.get!(Sandbox, args[:sandbox_id])
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")

      {:ok, _} =
        Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "idle"})

      send(test, {:bindings, original.id, replacement.id})
      {:error, :max_children}
    end)

    assert {:ok, conv} = start(ctx)
    assert_received {:bindings, original_id, replacement_id}
    assert conv.status == "idle"
    assert conv.sandbox_id == replacement_id
    assert Repo.get!(Sandbox, original_id).status == "pending"
    assert Repo.get!(Sandbox, replacement_id).status == "ready"
  end

  test "a start error cannot overwrite an already-provisioned conversation", ctx do
    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      conv = Repo.get!(Conversation, args[:conversation_id])
      sandbox = Repo.get!(Sandbox, args[:sandbox_id])
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})
      {:error, :max_children}
    end)

    assert {:ok, conv} = start(ctx)
    assert conv.status == "idle"
    assert Repo.get!(Sandbox, conv.sandbox_id).status == "ready"
  end

  test "a cancelled parent keeps its terminal status", ctx do
    expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      conv = Repo.get!(Conversation, args[:conversation_id])
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
      {:error, :max_children}
    end)

    assert {:ok, conv} = start(ctx)
    assert conv.status == "terminated"
  end

  for change <- [:deleted, :reassigned] do
    @tag change: change
    test "a #{change} parent is not returned to the original caller", ctx do
      other = insert_active_user()

      expect(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
        conv = Repo.get!(Conversation, args[:conversation_id])

        case ctx.change do
          :deleted -> Repo.delete!(conv)
          :reassigned -> conv |> Ecto.Changeset.change(user_id: other.id) |> Repo.update!()
        end

        {:error, :max_children}
      end)

      assert {:error, :not_found} = start(ctx)
      assert [sandbox] = Repo.all(from s in Sandbox, where: s.user_id == ^ctx.user.id)
      assert sandbox.status == "pending"
    end
  end

  defp start(ctx),
    do: Conversations.start_conversation(%{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id})
end
