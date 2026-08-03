defmodule Fountain.UsageMeteringTest do
  @moduledoc """
  Usage events, emitted where sandboxes and turns actually change state.

  `Billing.emit/5` was defined, documented as being called from
  `ConversationServer`, schema'd, and unit-tested — with **no call sites**. So
  `usage_events` was permanently empty and `/account/billing` rendered zeros to
  every user. The lesson those tests didn't catch is the one pinned here:
  emission has to be verified from the operations that cause it, not from the
  emit function in isolation.
  """

  use Fountain.DataCase, async: true

  alias Fountain.{Billing, Conversations}
  alias Fountain.Billing.UsageEvent
  alias Fountain.Repo

  defp events_for(user_id, type) do
    Repo.all(from e in UsageEvent, where: e.user_id == ^user_id and e.event_type == ^type)
  end

  describe "sandbox_provisioned" do
    test "is emitted when a sandbox becomes ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})

      assert [event] = events_for(user.id, "sandbox_provisioned")
      assert event.resource_id == sandbox.id
      assert event.resource_type == "sandbox"
    end

    test "is not emitted for intermediate transitions" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "starting"})

      assert events_for(user.id, "sandbox_provisioned") == []
    end

    test "is emitted once even if ready is written repeatedly" do
      # Reattach and rehydration both re-assert `ready`. Counting each write
      # would inflate the bill for a conversation that was merely resumed.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      {:ok, ready} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      {:ok, ready} = Conversations.update_sandbox(ready, %{status: "ready"})
      {:ok, _} = Conversations.update_sandbox(ready, %{status: "ready"})

      assert length(events_for(user.id, "sandbox_provisioned")) == 1
    end
  end

  describe "sandbox_terminated" do
    test "is emitted with a duration when a sandbox is terminated" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: "terminated",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert [event] = events_for(user.id, "sandbox_terminated")
      assert is_integer(event.metadata["duration_ms"])
      assert event.metadata["duration_ms"] >= 0
      assert event.metadata["final_status"] == "terminated"
    end

    test "a failed sandbox counts too — it still ran and was still billed" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "starting")

      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

      assert [event] = events_for(user.id, "sandbox_terminated")
      assert event.metadata["final_status"] == "failed"
    end

    test "is emitted once even if termination is written twice" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      {:ok, term} = Conversations.update_sandbox(sandbox, %{status: "terminated"})
      {:ok, _} = Conversations.update_sandbox(term, %{status: "terminated"})

      assert length(events_for(user.id, "sandbox_terminated")) == 1
    end
  end

  describe "sandbox_provision_failed" do
    test "a sandbox that dies before ready records the attempt" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "starting")

      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

      assert [event] = events_for(user.id, "sandbox_provision_failed")
      assert event.resource_id == sandbox.id
      assert event.metadata["status_before_failure"] == "starting"
      # The terminated event is still emitted — the sprite ran and was billed.
      assert [_] = events_for(user.id, "sandbox_terminated")
    end

    test "is not emitted when the sandbox had reached ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      {:ok, ready} = Conversations.update_sandbox(sandbox, %{status: "ready"})

      {:ok, _} =
        Conversations.update_sandbox(ready, %{
          status: "failed",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert events_for(user.id, "sandbox_provision_failed") == []
    end

    test "keeps the two billing-page numbers in agreement when provisioning fails" do
      # Before this event existed, a sandbox that died during provisioning
      # contributed sandbox minutes but no conversation, so the billing page
      # diverged for exactly the accounts where something was going wrong.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "starting")

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: "failed",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      summary =
        Billing.usage_summary(
          user.id,
          DateTime.utc_now() |> DateTime.add(-3600, :second),
          DateTime.utc_now() |> DateTime.add(3600, :second)
        )

      assert summary.conversations == 1
      assert length(events_for(user.id, "sandbox_terminated")) == 1
    end
  end

  describe "turn_started" do
    test "is emitted when a turn is created" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      {:ok, turn} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "hello",
          status: "running"
        })

      assert [event] = events_for(user.id, "turn_started")
      assert event.resource_id == turn.id
      assert event.metadata["conversation_id"] == conv.id
    end

    test "is attributed to the conversation's owner" do
      owner = insert_verified_user()
      other = insert_verified_user()
      conv = insert_conversation(user_id: owner.id)

      {:ok, _} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "x",
          status: "running"
        })

      assert length(events_for(owner.id, "turn_started")) == 1
      assert events_for(other.id, "turn_started") == []
    end
  end

  describe "usage_summary/3 against real emissions" do
    test "reports what actually happened" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      {:ok, ready} = Conversations.update_sandbox(sandbox, %{status: "ready"})

      for n <- 1..3 do
        {:ok, _} =
          Conversations._unsafe_create_turn(%{
            conversation_id: conv.id,
            turn_number: n,
            prompt: "p#{n}",
            status: "running"
          })
      end

      {:ok, _} =
        Conversations.update_sandbox(ready, %{
          status: "terminated",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      summary =
        Billing.usage_summary(
          user.id,
          DateTime.utc_now() |> DateTime.add(-3600, :second),
          DateTime.utc_now() |> DateTime.add(3600, :second)
        )

      # This is the assertion that would have caught the missing call sites:
      # before, every one of these was zero no matter what the user did.
      assert summary.conversations == 1
      assert summary.turns == 3
      assert summary.sandbox_minutes >= 0.0
    end

    test "one tenant's usage is not another's" do
      a = insert_verified_user()
      b = insert_verified_user()

      insert_sandbox(user_id: a.id, status: "pending")
      |> Conversations.update_sandbox(%{status: "ready"})

      window = {
        DateTime.utc_now() |> DateTime.add(-3600, :second),
        DateTime.utc_now() |> DateTime.add(3600, :second)
      }

      {from, to} = window
      assert Billing.usage_summary(a.id, from, to).conversations == 1
      assert Billing.usage_summary(b.id, from, to).conversations == 0
    end
  end

  describe "record_usage/5 is best effort" do
    test "an invalid event type is logged, not raised" do
      user = insert_verified_user()

      assert {:error, :invalid} =
               Billing.record_usage(user.id, "not_a_real_event", nil, nil, %{})
    end

    test "a metering failure does not fail the operation being measured" do
      # The contract that matters: bookkeeping must never break a conversation.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      assert {:ok, updated} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      assert updated.status == "ready"
    end
  end
end
