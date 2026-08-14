defmodule Fountain.Runtimes.ACPTest do
  use ExUnit.Case, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Runtimes.ACP

  defp agent(attrs), do: struct(Agent, attrs)

  describe "enabled?/1" do
    test "a property of the runtime alone — agent, runtime string, or nil" do
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{}))
      assert ACP.enabled?("claude")

      refute ACP.enabled?(nil)
    end

    test "the retired metadata flag is ignored in both directions" do
      # The per-agent flag (gate 2's opt-in, then the default-on opt-out) died
      # with the legacy spawn path: for a supported runtime there is nothing
      # left to opt out into, so stale metadata must not route anywhere.
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => false}))
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => true}))
      refute ACP.enabled?(agent(runtime: "gemini", metadata: %{"acp" => true}))
    end

    test "a blocked runtime cannot be switched on at all" do
      # gemini is converted and verified for turn 1, but loading a session
      # erases it: the load path's own chat recorder overwrites the message
      # list in the session file before the lookup reads it (#658, mechanism in
      # the ACP moduledoc). A working first turn followed by an amnesiac agent
      # — and an unrecoverable conversation — is worse than the
      # resume-by-guessing it replaces, so the flag must not reach it.
      assert %{"gemini" => _} = ACP.blocked_runtimes()
      refute "gemini" in ACP.supported_runtimes()
      refute ACP.enabled?(agent(runtime: "gemini", metadata: %{"acp" => true}))
    end

    test "a blocked runtime keeps its adapter entry, so the work is not lost" do
      assert {"gemini", ["--acp"]} = ACP.command("gemini")
      assert ACP.cwd("gemini") == "/tmp/gemini-workspace"
    end

    test "every supported runtime speaks ACP unconditionally" do
      for runtime <- ACP.supported_runtimes() do
        assert ACP.enabled?(runtime), "expected #{runtime} to be ACP-enabled"
        assert ACP.enabled?(agent(runtime: runtime, metadata: %{}))
      end
    end

    test "a runtime with no adapter entry stays legacy" do
      # For an unconvertible runtime the legacy path is the only path.
      refute ACP.enabled?("somethingelse")
      refute ACP.enabled?(agent(runtime: "somethingelse", metadata: %{}))
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

  describe "per-runtime launch" do
    test "claude runs an installed adapter, pinned to an exact version" do
      # An unpinned adapter can stop advertising sessionCapabilities.resume in a
      # point release, which downgrades every conversation to a full history
      # replay per turn with no error anywhere.
      assert ACP.adapter_bin("claude") == "claude-agent-acp"
      assert {"claude-agent-acp", []} = ACP.command("claude")

      assert ACP.adapter_spec("claude") =~
               ~r{^@agentclientprotocol/claude-agent-acp@\d+\.\d+\.\d+$}
    end

    test "gemini speaks ACP natively, so there is nothing to pin" do
      assert {"gemini", ["--acp"]} = ACP.command("gemini")
      assert is_nil(ACP.adapter_spec("gemini"))
    end

    test "the held-back gemini entry still points at the right workspace" do
      # gemini walks up from cwd looking for a .git; pointing it at
      # /home/sprite reintroduces the EACCES noise the workspace exists to
      # avoid, and leaves MemoryDiscovery crawling /home.
      assert ACP.cwd("gemini") == "/tmp/gemini-workspace"
      assert ACP.cwd("claude") == "/home/sprite"
    end

    test "codex runs a pinned adapter; opencode runs its own subcommand" do
      assert {"codex-acp", []} = ACP.command("codex")
      assert ACP.adapter_spec("codex") =~ ~r{^@agentclientprotocol/codex-acp@\d+\.\d+\.\d+$}

      # opencode's `acp` subcommand starts a local HTTP server inside the
      # sprite and drives it through its own SDK — a heavier process model than
      # the others, but nothing for us to install: OpenCode.prepare_sprite/3
      # already bun-installs it.
      assert {"opencode", ["acp"]} = ACP.command("opencode")
      assert is_nil(ACP.adapter_spec("opencode"))
      assert :ok = ACP.install(%{name: "s"}, "opencode", [])
    end

    test "each runtime runs where its own runtime module prepared" do
      assert ACP.cwd("opencode") == "/tmp/opencode-workspace"
      assert ACP.cwd("codex") == "/home/sprite"
    end

    test "an unknown runtime raises rather than spawning something arbitrary" do
      assert_raise ArgumentError, fn -> ACP.command("nonesuch") end
    end

    test "a native runtime needs no install" do
      # No Sprites stub here on purpose: if this tried to shell out, the test
      # would fail rather than quietly pass.
      assert :ok = ACP.install(%{name: "s"}, "gemini", [])
    end
  end
end
