defmodule Fountain.Conversations.McpServersTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Conversations.McpServers
  alias Fountain.Environments.Environment

  describe "substitute_agent/3" do
    test "no agent is no agent" do
      assert {:ok, nil} = McpServers.substitute_agent(nil, nil, %{})
    end

    test "resolves ${VAR} against env vars, with secrets winning on collision" do
      agent = %Agent{mcp_servers: %{"svc" => %{"url" => "${HOST}/${TOKEN}", "port" => 1}}}
      env = %Environment{env_vars: %{"TOKEN" => "from-env", HOST: "h"}}

      assert {:ok, %Agent{mcp_servers: mcp}} =
               McpServers.substitute_agent(agent, env, %{"TOKEN" => "from-vault"})

      assert mcp == %{"svc" => %{"url" => "h/from-vault", "port" => 1}}
    end

    test "an agent with no servers passes through" do
      assert {:ok, %Agent{mcp_servers: %{}}} =
               McpServers.substitute_agent(%Agent{mcp_servers: nil}, nil, %{})
    end

    test "names every missing variable" do
      agent = %Agent{mcp_servers: %{"a" => "${B}", "c" => "${A}"}}

      assert {:error, {:missing_vars, ["A", "B"]}} =
               McpServers.substitute_agent(agent, nil, %{})
    end
  end

  describe "substitution_vars/2" do
    test "no environment is just the secrets" do
      assert McpServers.substitution_vars(nil, %{"K" => "v"}) == %{"K" => "v"}
    end

    test "env keys and values become strings; secrets override" do
      env = %Environment{env_vars: %{"K" => "env", PORT: 8080}}

      assert McpServers.substitution_vars(env, %{"K" => "secret"}) ==
               %{"PORT" => "8080", "K" => "secret"}
    end

    test "nil env_vars is an empty map" do
      assert McpServers.substitution_vars(%Environment{env_vars: nil}, %{}) == %{}
    end
  end

  describe "the Fountain-served lists without a callback token" do
    test "are empty, whatever the conversation" do
      conv = insert_conversation(channel_id: Fountain.Team.channel())
      conv = %{conv | caller_tools: [%{"name" => "x"}]}

      assert McpServers.buzz(conv.id, nil) == []
      assert McpServers.team(conv.id, nil) == []
      assert McpServers.team_comms(conv.id, nil) == []
      assert McpServers.caller(conv, nil) == []
      assert McpServers.fountain_served(conv, nil) == []
    end
  end

  describe "team/2" do
    test "serves the team tools to a conversation on the team channel only" do
      team = insert_conversation(channel_id: Fountain.Team.channel())
      other = insert_conversation()

      assert [%{name: name, type: "http", url: url, headers: [header]}] =
               McpServers.team(team.id, "tok")

      assert name == Fountain.Team.Mcp.mcp_name()
      assert String.ends_with?(url, "/api/mcp/team/" <> team.id)
      assert header == %{name: "Authorization", value: "Bearer tok"}

      assert McpServers.team(other.id, "tok") == []
    end
  end

  describe "caller/2" do
    test "serves the caller bridge when the row has tools registered" do
      conv = %{id: "c1", caller_tools: [%{"name" => "x"}]}

      assert [%{name: "fountain-caller", type: "http", url: url}] =
               McpServers.caller(conv, "tok")

      assert String.ends_with?(url, "/api/mcp/caller/c1")
      assert McpServers.caller(%{id: "c1", caller_tools: []}, "tok") == []
    end
  end

  describe "fountain_served/2" do
    test "is buzz, team, team comms, caller, in that order" do
      # No Buzz identity and no teammate contact on this row, so the first
      # and third lists are empty; the order of the two that remain is the
      # order the server appended them before #1371.
      conv = insert_conversation(channel_id: Fountain.Team.channel())
      conv = %{conv | caller_tools: [%{"name" => "x"}]}

      assert [%{name: team_name}, %{name: "fountain-caller"}] =
               McpServers.fountain_served(conv, "tok")

      assert team_name == Fountain.Team.Mcp.mcp_name()
    end

    test "is empty for an ordinary conversation" do
      assert McpServers.fountain_served(insert_conversation(), "tok") == []
    end
  end
end
