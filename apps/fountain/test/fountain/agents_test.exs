defmodule Fountain.AgentsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents

  describe "create_agent/1" do
    test "creates an agent with valid attrs" do
      user = insert_verified_user()
      attrs = agent_attrs(user_id: user.id)

      assert {:ok, agent} = Agents.create_agent(attrs)
      assert agent.user_id == user.id
      assert agent.name == attrs["name"]
    end

    test "returns error changeset with missing required fields" do
      assert {:error, changeset} = Agents.create_agent(%{})
      assert changeset.errors != []
    end
  end

  describe "get_agent/2" do
    test "returns agent scoped to user" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert fetched = Agents.get_agent(agent.id, user.id)
      assert fetched.id == agent.id
    end

    test "returns nil for agent belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      agent = insert_agent(user_id: user_a.id)

      assert Agents.get_agent(agent.id, user_b.id) == nil
    end

    test "returns nil for non-existent id" do
      user = insert_verified_user()
      assert Agents.get_agent(Ecto.UUID.generate(), user.id) == nil
    end
  end

  describe "get_agent!/2" do
    test "raises for agent belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      agent = insert_agent(user_id: user_a.id)

      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent!(agent.id, user_b.id)
      end
    end
  end

  describe "list_agents/2" do
    test "returns only agents for the given user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      agent_a = insert_agent(user_id: user_a.id)
      _agent_b = insert_agent(user_id: user_b.id)

      results = Agents.list_agents(user_a.id, [])
      assert length(results) == 1
      assert hd(results).id == agent_a.id
    end

    test "returns empty list when user has no agents" do
      user = insert_verified_user()
      assert Agents.list_agents(user.id, []) == []
    end

    test "search filter matches agent name" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, name: "alpha bot")
      insert_agent(user_id: user.id, name: "beta bot")

      results = Agents.list_agents(user.id, search: "alpha")
      assert length(results) == 1
      assert hd(results).name == "alpha bot"
    end

    test "search filter returns empty when no match" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, name: "gamma bot")

      results = Agents.list_agents(user.id, search: "zzz")
      assert results == []
    end

    test "runtimes filter returns only matching agents" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, runtime: "claude")
      insert_agent(user_id: user.id, runtime: "claude")

      results = Agents.list_agents(user.id, runtimes: ["claude"])
      assert length(results) == 2
    end
  end

  describe "update_agent/2" do
    test "updates agent fields" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:ok, updated} = Agents.update_agent(agent, %{"name" => "renamed"})
      assert updated.name == "renamed"
    end

    test "returns error changeset for invalid update" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, changeset} = Agents.update_agent(agent, %{"name" => nil})
      assert changeset.errors != []
    end
  end

  describe "delete_agent/1" do
    test "deletes the agent" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:ok, _deleted} = Agents.delete_agent(agent)
      assert Agents.get_agent(agent.id, user.id) == nil
    end
  end
end
