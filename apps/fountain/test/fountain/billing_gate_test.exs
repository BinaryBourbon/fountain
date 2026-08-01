defmodule Fountain.BillingGateTest do
  @moduledoc """
  The subscription gate, checked where sprites are actually provisioned.

  ADR 0006 claimed this backstop existed in `ConversationServer.init/1`. It did
  not, and the gap was not theoretical: `POST /api/conversations/:id/prompts`
  wakes a dormant conversation, which provisions a brand-new sprite, and it
  never went near a billing check. Anyone with one existing conversation could
  keep spending indefinitely after cancelling.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Billing, Conversations}

  defp user_with_status(status) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> Fountain.Accounts.User.billing_changeset(%{subscription_status: status})
      |> Fountain.Repo.update()

    user
  end

  describe "check_active/1" do
    test "allows trialing and active" do
      assert :ok = Billing.check_active(user_with_status("trialing"))
      assert :ok = Billing.check_active(user_with_status("active"))
    end

    test "refuses past_due and canceled" do
      assert {:error, :subscription_required} = Billing.check_active(user_with_status("past_due"))
      assert {:error, :subscription_required} = Billing.check_active(user_with_status("canceled"))
    end

    test "accepts a user id as well as a struct" do
      assert :ok = Billing.check_active(user_with_status("active").id)

      assert {:error, :subscription_required} =
               Billing.check_active(user_with_status("canceled").id)
    end

    test "fails closed on an unknown user id" do
      assert {:error, :subscription_required} = Billing.check_active(Ecto.UUID.generate())
    end
  end

  describe "start_conversation/1" do
    test "is refused for a canceled subscription" do
      user = user_with_status("canceled")
      agent = insert_agent(user_id: user.id)

      assert {:error, :subscription_required} =
               Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end

    test "allocates no sandbox when refused" do
      user = user_with_status("past_due")
      agent = insert_agent(user_id: user.id)

      assert {:error, :subscription_required} =
               Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert Fountain.Quotas.active_sandbox_count(user.id) == 0
    end

    test "still works while trialing" do
      user = user_with_status("trialing")
      agent = insert_agent(user_id: user.id)
      stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, _} =
               Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end
  end

  describe "wake_conversation/2 — the path that was ungated" do
    test "is refused for a canceled subscription" do
      user = user_with_status("canceled")
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")

      assert {:error, :subscription_required} = Conversations.wake_conversation(conv.id, "hi")
    end

    test "provisions no replacement sandbox when refused" do
      user = user_with_status("canceled")
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
      before = Fountain.Quotas.active_sandbox_count(user.id)

      assert {:error, :subscription_required} = Conversations.wake_conversation(conv.id, "hi")
      assert Fountain.Quotas.active_sandbox_count(user.id) == before
    end

    test "an active subscription still wakes" do
      user = user_with_status("active")
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
      stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, _} = Conversations.wake_conversation(conv.id, "hi")
    end
  end

  describe "gate ordering" do
    test "billing is reported before quota" do
      # A cancelled tenant sitting at their sandbox cap should be told to fix
      # their subscription, not to terminate conversations that would not help.
      user = user_with_status("canceled")
      agent = insert_agent(user_id: user.id)
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, :subscription_required} =
               Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end
  end
end
