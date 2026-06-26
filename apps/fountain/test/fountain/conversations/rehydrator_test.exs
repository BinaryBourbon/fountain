defmodule Fountain.Conversations.RehydratorTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.Rehydrator

  describe "leader election" do
    test "a lone node (no peers) is always the leader" do
      assert Rehydrator.leader?(:"fountain_server@10.0.0.1", [])

      assert Rehydrator.leader_node(:"fountain_server@10.0.0.1", []) ==
               :"fountain_server@10.0.0.1"
    end

    test "the lowest node name wins, regardless of discovery order" do
      self_node = :"fountain_server@10.0.0.1"
      peers = [:"fountain_server@10.0.0.2", :"fountain_server@10.0.0.3"]

      assert Rehydrator.leader?(self_node, peers)
      assert Rehydrator.leader_node(self_node, peers) == self_node
    end

    test "a non-lowest node defers to the leader" do
      self_node = :"fountain_server@10.0.0.3"
      peers = [:"fountain_server@10.0.0.1", :"fountain_server@10.0.0.2"]

      refute Rehydrator.leader?(self_node, peers)
      assert Rehydrator.leader_node(self_node, peers) == :"fountain_server@10.0.0.1"
    end

    test "election is consistent across the cluster: exactly one leader" do
      a = :"fountain_server@10.0.0.1"
      b = :"fountain_server@10.0.0.2"
      c = :"fountain_server@10.0.0.3"
      cluster = [a, b, c]

      # Each node evaluates against itself + its peers; all must agree.
      leaders =
        for node <- cluster, Rehydrator.leader?(node, cluster -- [node]), do: node

      assert leaders == [a]
    end
  end
end
