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

  describe "_unsafe_list_agents/1" do
    test "returns agents across all users (no user_id filter)" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      agent_a = insert_agent(user_id: user_a.id)
      agent_b = insert_agent(user_id: user_b.id)

      ids = Agents._unsafe_list_agents() |> Enum.map(& &1.id)
      assert agent_a.id in ids
      assert agent_b.id in ids
    end

    test "search filter matches agent name" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, name: "unsafe-alpha")
      insert_agent(user_id: user.id, name: "unsafe-beta")

      results = Agents._unsafe_list_agents(search: "unsafe-alpha")
      assert length(results) == 1
      assert hd(results).name == "unsafe-alpha"
    end

    test "runtimes filter returns only matching agents" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, runtime: "gemini")
      insert_agent(user_id: user.id, runtime: "claude")

      results = Agents._unsafe_list_agents(runtimes: ["gemini"])
      assert Enum.all?(results, &(&1.runtime == "gemini"))
      assert Enum.any?(results, &(&1.runtime == "gemini"))
    end
  end

  describe "_unsafe_get_agent/1 and _unsafe_get_agent!/1" do
    test "_unsafe_get_agent returns the agent by id" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      result = Agents._unsafe_get_agent(agent.id)
      assert result.id == agent.id
    end

    test "_unsafe_get_agent returns nil for unknown id" do
      assert Agents._unsafe_get_agent(Ecto.UUID.generate()) == nil
    end

    test "_unsafe_get_agent! returns the agent by id" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      result = Agents._unsafe_get_agent!(agent.id)
      assert result.id == agent.id
    end

    test "_unsafe_get_agent! raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents._unsafe_get_agent!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_agents/2 - env_ids filter" do
    test "env_ids: [\"none\"] returns only agents with no environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      agent_no_env = insert_agent(user_id: user.id)
      _agent_with_env = insert_agent(user_id: user.id, environment_id: env.id)

      results = Agents.list_agents(user.id, env_ids: ["none"])
      ids = Enum.map(results, & &1.id)
      assert agent_no_env.id in ids
      refute Enum.any?(results, &(&1.environment_id != nil))
    end

    test "env_ids: [env.id] returns only agents with that environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      _agent_no_env = insert_agent(user_id: user.id)
      agent_with_env = insert_agent(user_id: user.id, environment_id: env.id)

      results = Agents.list_agents(user.id, env_ids: [env.id])
      assert length(results) == 1
      assert hd(results).id == agent_with_env.id
    end

    test "env_ids: [\"none\", env.id] returns agents with no env OR that env" do
      user = insert_verified_user()
      env_a = insert_env(user_id: user.id)
      env_b = insert_env(user_id: user.id)
      agent_no_env = insert_agent(user_id: user.id)
      agent_env_a = insert_agent(user_id: user.id, environment_id: env_a.id)
      _agent_env_b = insert_agent(user_id: user.id, environment_id: env_b.id)

      results = Agents.list_agents(user.id, env_ids: ["none", env_a.id])
      ids = Enum.map(results, & &1.id)
      assert agent_no_env.id in ids
      assert agent_env_a.id in ids
      assert length(results) == 2
    end
  end

  describe "list_agents/2 - has_skills filter" do
    test "has_skills: true returns only agents with non-empty skills list" do
      user = insert_verified_user()
      _agent_no_skills = insert_agent(user_id: user.id)

      agent_with_skills =
        insert_agent(user_id: user.id,
          skills: [%{"name" => "foo", "content" => "bar"}])

      results = Agents.list_agents(user.id, has_skills: true)
      ids = Enum.map(results, & &1.id)
      assert agent_with_skills.id in ids
      refute Enum.any?(results, &(&1.skills == []))
    end

    test "has_skills: false (default) returns all agents including those without skills" do
      user = insert_verified_user()
      agent_no_skills = insert_agent(user_id: user.id)
      agent_with_skills =
        insert_agent(user_id: user.id,
          skills: [%{"name" => "foo", "content" => "bar"}])

      results = Agents.list_agents(user.id, has_skills: false)
      ids = Enum.map(results, & &1.id)
      assert agent_no_skills.id in ids
      assert agent_with_skills.id in ids
    end
  end

  describe "list_agents/2 - has_mcp filter" do
    test "has_mcp: true returns only agents with non-empty mcp_servers map" do
      user = insert_verified_user()
      _agent_no_mcp = insert_agent(user_id: user.id)

      agent_with_mcp =
        insert_agent(user_id: user.id,
          mcp_servers: %{"my-server" => %{"url" => "http://localhost:8080"}})

      results = Agents.list_agents(user.id, has_mcp: true)
      ids = Enum.map(results, & &1.id)
      assert agent_with_mcp.id in ids
      refute Enum.any?(results, &(&1.mcp_servers == %{}))
    end

    test "has_mcp: false (default) returns all agents" do
      user = insert_verified_user()
      agent_no_mcp = insert_agent(user_id: user.id)

      agent_with_mcp =
        insert_agent(user_id: user.id,
          mcp_servers: %{"my-server" => %{"url" => "http://localhost:8080"}})

      results = Agents.list_agents(user.id, has_mcp: false)
      ids = Enum.map(results, & &1.id)
      assert agent_no_mcp.id in ids
      assert agent_with_mcp.id in ids
    end
  end
end
