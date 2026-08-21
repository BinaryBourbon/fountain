defmodule Fountain.ConversationsTurnsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  # Turns: numbering, lookup, creation and update.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # Turns
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_turns/1" do
    test "returns empty list when conversation has no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations._unsafe_list_turns(conv.id) == []
    end

    test "returns all turns for the conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv)
      t2 = insert_turn(conv)

      ids = Conversations._unsafe_list_turns(conv.id) |> Enum.map(& &1.id)
      assert t1.id in ids
      assert t2.id in ids
    end

    test "orders turns by turn_number ascending" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv)
      t2 = insert_turn(conv)

      [first, second] = Conversations._unsafe_list_turns(conv.id)
      assert first.turn_number < second.turn_number
      assert first.id == t1.id
      assert second.id == t2.id
    end

    test "does not return turns from other conversations" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv1)
      _t2 = insert_turn(conv2)

      results = Conversations._unsafe_list_turns(conv1.id)
      assert length(results) == 1
      assert hd(results).id == t1.id
    end
  end

  describe "get_turn_by_conversation/3" do
    test "returns the turn when turn_id, conversation_id and user_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      result = Conversations.get_turn_by_conversation(turn.id, conv.id, user.id)
      assert result.id == turn.id
    end

    test "returns nil when turn_id does not exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.get_turn_by_conversation(Ecto.UUID.generate(), conv.id, user.id) == nil
    end

    test "returns nil when turn belongs to a different conversation" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      turn = insert_turn(conv1)

      assert Conversations.get_turn_by_conversation(turn.id, conv2.id, user.id) == nil
    end

    test "returns nil when the conversation belongs to a different user" do
      owner = insert_verified_user()
      other = insert_verified_user()
      conv = insert_conversation(user_id: owner.id)
      turn = insert_turn(conv)

      assert Conversations.get_turn_by_conversation(turn.id, conv.id, other.id) == nil
    end
  end

  describe "_unsafe_next_turn_number/1" do
    test "returns 1 when conversation has no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations._unsafe_next_turn_number(conv.id) == 1
    end

    test "returns max_turn_number + 1 when turns exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _t1 = insert_turn(conv)
      _t2 = insert_turn(conv)

      assert Conversations._unsafe_next_turn_number(conv.id) == 3
    end

    test "is not affected by turns from other conversations" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      _t1 = insert_turn(conv1)
      _t2 = insert_turn(conv1)
      _t3 = insert_turn(conv1)

      assert Conversations._unsafe_next_turn_number(conv2.id) == 1
    end
  end

  describe "_unsafe_create_turn/1" do
    test "creates a turn with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "Hello, world",
        status: "pending"
      }

      assert {:ok, turn} = Conversations._unsafe_create_turn(attrs)
      assert turn.conversation_id == conv.id
      assert turn.turn_number == 1
      assert turn.prompt == "Hello, world"
      assert turn.status == "pending"
    end

    test "returns error changeset when required fields are missing" do
      assert {:error, changeset} = Conversations._unsafe_create_turn(%{})
      assert changeset.valid? == false
      assert errors_on(changeset)[:conversation_id]
      assert errors_on(changeset)[:turn_number]
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "test",
        status: "bogus"
      }

      assert {:error, changeset} = Conversations._unsafe_create_turn(attrs)
      assert errors_on(changeset)[:status]
    end
  end

  describe "_unsafe_update_turn/2" do
    test "updates a turn with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:ok, updated} = Conversations._unsafe_update_turn(turn, %{status: "completed"})
      assert updated.id == turn.id
      assert updated.status == "completed"
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:error, changeset} = Conversations._unsafe_update_turn(turn, %{status: "invalid"})
      assert errors_on(changeset)[:status]
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
end
