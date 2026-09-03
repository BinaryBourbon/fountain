defmodule Fountain.ActivationTest do
  use Fountain.DataCase, async: true

  alias Fountain.Activation
  alias Fountain.Conversations

  # One ACP `agent_message_chunk`: the shape a runtime writes assistant text
  # in, and what `Blocks.assistant_text/2` parses `reply_text` out of.
  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  defp at(hours_ago) do
    DateTime.utc_now()
    |> DateTime.add(-round(hours_ago * 3600), :second)
    |> DateTime.truncate(:second)
  end

  describe "first_reply_by_user/0" do
    test "empty when nobody has replied" do
      user = insert_verified_user()
      insert_conversation(user_id: user.id)

      assert Activation.first_reply_by_user() == %{}
      assert Activation.first_reply_at(user.id) == nil
    end

    test "the earliest replied turn, across conversations" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      other = insert_conversation(user_id: user.id)

      insert_turn(other, %{status: "completed", reply_text: "later", ended_at: at(1)})
      insert_turn(conv, %{status: "completed", reply_text: "first", ended_at: at(4)})

      first = Activation.first_reply_at(user.id)

      assert DateTime.compare(first, at(4)) == :eq
      assert Activation.first_reply_by_user() == %{user.id => first}
    end

    test "a turn with no assistant text is not a reply" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      insert_turn(conv, %{status: "completed", ended_at: at(1)})
      insert_turn(conv, %{status: "failed", reply_text: "", ended_at: at(1)})

      assert Activation.first_reply_by_user() == %{}
    end

    test "accounts are separate" do
      one = insert_verified_user()
      two = insert_verified_user()

      insert_turn(insert_conversation(user_id: one.id), %{
        status: "completed",
        reply_text: "hi",
        ended_at: at(2)
      })

      assert Map.keys(Activation.first_reply_by_user()) == [one.id]
      assert Activation.first_reply_at(two.id) == nil
    end
  end

  describe "turn_replied/1" do
    test "is a no-op for a turn with no reply" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})

      assert Activation.turn_replied(turn) == :ok
    end

    test "does not raise when the turn's conversation is gone" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "completed", reply_text: "hi", ended_at: at(1)})

      Repo.delete!(conv)

      assert Activation.turn_replied(turn) == :ok
    end

    test "answers :ok for the first reply and for every one after it" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      first = insert_turn(conv, %{status: "completed", reply_text: "one", ended_at: at(3)})
      second = insert_turn(conv, %{status: "completed", reply_text: "two", ended_at: at(2)})

      assert Activation.turn_replied(first) == :ok
      assert Activation.turn_replied(second) == :ok
    end
  end

  describe "the seam in Conversations._unsafe_update_turn/2" do
    test "ending a turn with assistant text activates the account" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})

      insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_text("hello")})

      {:ok, ended} =
        Conversations._unsafe_update_turn(turn, %{status: "completed", ended_at: at(0)})

      assert ended.reply_text =~ "hello"
      assert Activation.first_reply_at(user.id) != nil
    end

    test "ending a turn that said nothing does not activate the account" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})

      {:ok, ended} =
        Conversations._unsafe_update_turn(turn, %{status: "completed", ended_at: at(0)})

      assert ended.reply_text == nil
      assert Activation.first_reply_at(user.id) == nil
    end
  end

  describe "onboarding_completed_at" do
    test "is stamped at the first reply, not before it" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})

      refute Repo.reload!(user).onboarding_completed_at

      insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_text("hello")})
      {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "completed", ended_at: at(0)})

      assert Repo.reload!(user).onboarding_completed_at
    end

    test "is not stamped by a turn that said nothing" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})

      {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "completed", ended_at: at(0)})

      refute Repo.reload!(user).onboarding_completed_at
    end

    test "an account that was already onboarded keeps its original timestamp" do
      user = insert_verified_user()
      earlier = at(48)
      Repo.update!(Ecto.Changeset.change(user, onboarding_completed_at: earlier))

      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})
      insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_text("hello")})
      {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "completed", ended_at: at(0)})

      assert DateTime.compare(Repo.reload!(user).onboarding_completed_at, earlier) == :eq
    end
  end

  describe "conversation_created/1" do
    test "is safe for the first conversation and for every one after it" do
      user = insert_verified_user()
      first = insert_conversation(user_id: user.id)
      second = insert_conversation(user_id: user.id)

      assert Activation.conversation_created(first) == :ok
      assert Activation.conversation_created(second) == :ok
    end

    test "does not raise for a conversation with no owner" do
      assert Activation.conversation_created(%Fountain.Conversations.Conversation{}) == :ok
    end
  end

  describe "funnel_events/0" do
    test "names the four steps of the PostHog funnel, in order" do
      assert Activation.funnel_events() == [
               "auth.email.verified",
               "onboarding.landing_viewed",
               "onboarding.request_sent",
               "activation.first_reply"
             ]
    end
  end
end
