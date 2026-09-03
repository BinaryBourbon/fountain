defmodule Fountain.Agents.StarterTest do
  @moduledoc """
  The default agent every account is verified into owning (ADR 0038, #1389).

  The behaviour worth pinning is in two halves. One is that it is *there*: a
  freshly verified account has exactly one agent, from every door that finishes
  a verification, and the trail says the system made it rather than the account.
  The other is that it is *ordinary*: nothing recreates it, nothing protects it,
  and no code path reads its name. The second half is the one a later change is
  likely to break, which is why deleting it is asserted here rather than assumed.
  """

  use Fountain.DataCase, async: true

  alias Fountain.{Accounts, Agents, Audit}
  alias Fountain.Agents.Starter

  defp agents(user), do: Agents.list_agents(user.id, [])

  defp agent_created_events(user) do
    user.id
    |> Audit.list_recent_for_user(200)
    |> Enum.filter(&(&1.action == "agent.created"))
  end

  describe "verification plants it" do
    test "a freshly verified account has exactly one agent" do
      user = insert_verified_user()

      assert [agent] = agents(user)
      assert agent.name == "starter"
      assert agent.runtime == "claude"
      assert agent.user_id == user.id
    end

    test "it is configured to need nothing: no environment, no MCP, no skills" do
      # The three things the first screen used to ask for. An agent that needed
      # any of them would not be an agent a blank account can run.
      assert [agent] = agents(insert_verified_user())

      assert agent.environment_id == nil
      assert agent.mcp_servers == %{}
      assert agent.skills == []
    end

    test "its prompt says what it is and whose inference key it runs on" do
      assert [agent] = agents(insert_verified_user())

      assert agent.system =~ "starter"
      assert agent.system =~ "platform key"
      assert agent.system =~ "credential"
      assert agent.description != ""
    end

    test "an unverified account has no agent" do
      # Nothing is created for an account until it verifies (ADR 0038).
      user = insert_user()

      assert agents(user) == []
    end
  end

  describe "the audit trail" do
    test "records agent.created with actor system:onboarding" do
      user = insert_verified_user()

      assert [event] = agent_created_events(user)
      assert event.actor == "system:onboarding"
      assert event.resource_type == "agent"
      assert event.metadata["name"] == "starter"
    end

    test "the actor is not `self` — the account did not ask for this" do
      user = insert_verified_user()

      refute Enum.any?(agent_created_events(user), &(&1.actor == "self"))
    end
  end

  describe "it is an ordinary agent" do
    test "it can be renamed, re-pointed and re-prompted like any other" do
      user = insert_verified_user()
      [agent] = agents(user)

      assert {:ok, updated} =
               Agents.update_agent(agent, %{
                 "name" => "mine",
                 "model" => "anthropic/claude-opus-5",
                 "system" => "Do as I say."
               })

      assert updated.name == "mine"
      assert updated.model == "anthropic/claude-opus-5"
    end

    test "deleting it leaves the account with no agents, and nothing brings it back" do
      user = insert_verified_user()
      [agent] = agents(user)

      assert {:ok, _} = Agents.delete_agent(agent)
      assert agents(user) == []

      # Re-running a verification route on an already-verified account is the
      # way this would resurrect. It must not: the account deleted it.
      {:ok, _} = Accounts.verify_email(Fountain.Repo.reload!(user))

      assert agents(user) == []
    end
  end

  describe "create_for/2" do
    test "is idempotent per account" do
      user = insert_verified_user()

      assert {:ok, :exists} = Starter.create_for(user.id)
      assert length(agents(user)) == 1
    end

    test "plants one for an account that has none" do
      user = insert_user_without_agents()

      assert {:ok, agent} = Starter.create_for(user.id)
      assert agent.name == "starter"
      assert [_] = agents(user)
    end

    test "the model is a canonical provider/model_id under the claude runtime" do
      # `Agent.changeset/2` rejects a mismatched prefix, so a wrong default here
      # would fail every verification's planting silently (best-effort) and
      # leave new accounts empty. Asserted rather than trusted to the insert.
      attrs = Starter.attrs(Ecto.UUID.generate())

      assert attrs["runtime"] == "claude"
      assert attrs["model"] =~ ~r"^anthropic/"
    end
  end
end
