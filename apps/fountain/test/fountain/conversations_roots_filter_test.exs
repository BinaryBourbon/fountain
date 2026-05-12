defmodule Fountain.ConversationsRootsFilterTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  describe "list_conversations/2 with roots_only" do
    setup do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      %{user: user, root: root, child: child}
    end

    test "default (no opts) returns all conversations", %{user: user, root: root, child: child} do
      ids = Conversations.list_conversations(user.id) |> Enum.map(& &1.id)
      assert root.id in ids
      assert child.id in ids
    end

    test "roots_only: false returns all conversations", %{user: user, root: root, child: child} do
      ids = Conversations.list_conversations(user.id, roots_only: false) |> Enum.map(& &1.id)
      assert root.id in ids
      assert child.id in ids
    end

    test "roots_only: true excludes child conversations", %{user: user, root: root, child: child} do
      ids = Conversations.list_conversations(user.id, roots_only: true) |> Enum.map(& &1.id)
      assert root.id in ids
      refute child.id in ids
    end

    test "roots_only: true includes conversations without a parent", %{user: user} do
      standalone = insert_conversation(user_id: user.id)
      ids = Conversations.list_conversations(user.id, roots_only: true) |> Enum.map(& &1.id)
      assert standalone.id in ids
    end

    test "scoping is not affected: does not return other users' roots" do
      other_user = insert_verified_user()
      other_root = insert_conversation(user_id: other_user.id)

      user = insert_verified_user()
      _my_root = insert_conversation(user_id: user.id)

      ids = Conversations.list_conversations(user.id, roots_only: true) |> Enum.map(& &1.id)
      refute other_root.id in ids
    end
  end
end
