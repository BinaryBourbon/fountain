defmodule Fountain.Runtimes.ACPTest do
  use ExUnit.Case, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Runtimes.ACP

  defp agent(attrs), do: struct(Agent, attrs)

  describe "enabled?/1" do
    test "requires both the flag and a runtime gate 1 cleared" do
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => true}))

      refute ACP.enabled?(agent(runtime: "claude", metadata: %{}))
      refute ACP.enabled?(agent(runtime: "gemini", metadata: %{"acp" => true}))
      refute ACP.enabled?(nil)
    end

    test "a truthy-looking value that is not true does not enable it" do
      # Metadata is user-editable JSON. "false" and "true" are both strings
      # there, and a string is not an opt-in.
      refute ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => "true"}))
      refute ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => 1}))
    end
  end

  describe "mcp_servers/1" do
    test "a stdio server carries no type, because the adapter branches on its absence" do
      # Sending `type: "stdio"` puts the entry down the http/sse branch of the
      # adapter's parser, which then looks for a `url` that is not there.
      [server] =
        ACP.mcp_servers(
          agent(mcp_servers: %{"files" => %{"command" => "mcp-files", "args" => ["--root", "/"]}})
        )

      refute Map.has_key?(server, :type)
      assert server.name == "files"
      assert server.command == "mcp-files"
      assert server.args == ["--root", "/"]
    end

    test "env becomes an array of name/value pairs, not a map" do
      # The detail that fails silently: a map is accepted as JSON and read as
      # nothing, so the server starts with no environment and surfaces much
      # later as a tool that cannot authenticate.
      [server] =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "gh" => %{"command" => "mcp-gh", "env" => %{"TOKEN" => "t", "HOST" => "h"}}
            }
          )
        )

      assert server.env == [%{name: "HOST", value: "h"}, %{name: "TOKEN", value: "t"}]
    end

    test "an absent or empty env is omitted rather than sent as an empty array" do
      [server] = ACP.mcp_servers(agent(mcp_servers: %{"a" => %{"command" => "x"}}))
      refute Map.has_key?(server, :env)

      [server] = ACP.mcp_servers(agent(mcp_servers: %{"a" => %{"command" => "x", "env" => %{}}}))
      refute Map.has_key?(server, :env)
    end

    test "http and sse servers keep their type and url" do
      servers =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "remote" => %{"type" => "http", "url" => "https://example.test/mcp"},
              "streamy" => %{"type" => "sse", "url" => "https://example.test/sse"}
            }
          )
        )

      assert [
               %{name: "remote", type: "http", url: "https://example.test/mcp"},
               %{name: "streamy", type: "sse", url: "https://example.test/sse"}
             ] = servers
    end

    test "http headers become name/value pairs too" do
      [server] =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "r" => %{
                "type" => "http",
                "url" => "https://x.test",
                "headers" => %{"Authorization" => "Bearer t"}
              }
            }
          )
        )

      assert server.headers == [%{name: "Authorization", value: "Bearer t"}]
    end

    test "servers are ordered by name so the adapter's session snapshot is stable" do
      # The adapter snapshots {cwd, mcpServers} per session and tears the
      # session down when the snapshot changes. Map iteration order is not
      # guaranteed, so an unsorted list would look like a different config on
      # some resumes and silently drop the session.
      names =
        agent(mcp_servers: %{"c" => %{}, "a" => %{}, "b" => %{}})
        |> ACP.mcp_servers()
        |> Enum.map(& &1.name)

      assert names == ["a", "b", "c"]
    end

    test "no servers is an empty list" do
      assert [] = ACP.mcp_servers(agent(mcp_servers: %{}))
      assert [] = ACP.mcp_servers(agent(mcp_servers: nil))
      assert [] = ACP.mcp_servers(nil)
    end
  end

  describe "initialize_params/0" do
    test "declares no filesystem or terminal capability" do
      params = ACP.initialize_params()

      assert params.clientCapabilities.terminal == false
      assert params.clientCapabilities.fs.readTextFile == false
      assert params.clientCapabilities.fs.writeTextFile == false
    end
  end

  describe "the pin" do
    test "names an exact version, never a range or a tag" do
      # An unpinned adapter can stop advertising sessionCapabilities.resume in a
      # point release, which downgrades every conversation to a full history
      # replay per turn with no error anywhere.
      assert ACP.adapter_spec() =~ ~r{^@agentclientprotocol/claude-agent-acp@\d+\.\d+\.\d+$}
    end
  end
end
