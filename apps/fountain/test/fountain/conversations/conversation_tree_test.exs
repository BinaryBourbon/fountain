defmodule Fountain.Conversations.ConversationTreeTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  # ---------------------------------------------------------------------------
  # get_conversation_tree/1
  # ---------------------------------------------------------------------------

  describe "get_conversation_tree/1" do
    test "returns empty list for a non-existent conversation_id" do
      assert Conversations.get_conversation_tree(Ecto.UUID.generate()) == []
    end

    test "returns a single-item list for a standalone conversation (no parent, no children)" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      tree = Conversations.get_conversation_tree(conv.id)

      assert length(tree) == 1
      assert hd(tree).id == conv.id
    end

    test "returns the full tree when querying by a leaf node" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      grandchild = insert_conversation(user_id: user.id, parent_conversation_id: child.id)

      tree = Conversations.get_conversation_tree(grandchild.id)
      ids = Enum.map(tree, & &1.id) |> Enum.sort()

      assert ids == Enum.sort([root.id, child.id, grandchild.id])
    end

    test "returns the full tree when querying by root" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      grandchild = insert_conversation(user_id: user.id, parent_conversation_id: child.id)

      tree = Conversations.get_conversation_tree(root.id)
      ids = Enum.map(tree, & &1.id) |> Enum.sort()

      assert ids == Enum.sort([root.id, child.id, grandchild.id])
    end

    test "returns the full tree when querying by a middle node" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      grandchild = insert_conversation(user_id: user.id, parent_conversation_id: child.id)

      tree = Conversations.get_conversation_tree(child.id)
      ids = Enum.map(tree, & &1.id) |> Enum.sort()

      assert ids == Enum.sort([root.id, child.id, grandchild.id])
    end

    test "does not include unrelated conversations" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      _unrelated = insert_conversation(user_id: user.id)

      tree = Conversations.get_conversation_tree(child.id)
      ids = Enum.map(tree, & &1.id)

      assert length(ids) == 2
      assert root.id in ids
      assert child.id in ids
    end

    test "each entry has the expected keys: :id, :source, :status, :parent_id" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      [entry] = Conversations.get_conversation_tree(conv.id)

      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :source)
      assert Map.has_key?(entry, :status)
      assert Map.has_key?(entry, :parent_id)
    end

    test "root entry has parent_id nil; child entry has parent_id equal to root id" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)

      tree = Conversations.get_conversation_tree(root.id)

      root_entry = Enum.find(tree, fn e -> e.id == root.id end)
      child_entry = Enum.find(tree, fn e -> e.id == child.id end)

      assert root_entry.parent_id == nil
      assert child_entry.parent_id == root.id
    end
  end
end
