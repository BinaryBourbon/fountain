defmodule Managoat.Runtimes.ACPTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.ACP

  # The library reads the agent as a map (`t:Managoat.Runtimes.agent/0`), so
  # a host's struct and a literal here are the same thing to it.
  defp agent(attrs), do: Map.new(attrs)

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

      # gemini was this test's counter-example while it was blocked; since #659
      # nothing is, so the only thing the flag still cannot switch on is a
      # runtime with no adapter entry at all.
      refute ACP.enabled?(agent(runtime: "nonesuch", metadata: %{"acp" => true}))
    end

    test "nothing is blocked any more: gemini ships behind the #659 workaround" do
      # gemini was held back because loading a session erased it — the load
      # path's own chat recorder overwrote the message list before the lookup
      # read it (#658). `Gemini.SessionStore` consolidates the store at the end
      # of every turn so the load cannot collide with what it is loading, which
      # is what let this switch on.
      assert ACP.blocked_runtimes() == %{}
      assert "gemini" in ACP.supported_runtimes()
      assert ACP.enabled?(agent(runtime: "gemini", metadata: %{}))
    end

    test "gemini's adapter entry still points at its own workspace" do
      # Not /home/sprite: gemini walks up from cwd looking for a .git, and
      # `Gemini.prepare_sandbox/3` git-inits exactly this directory.
      assert {"gemini", ["--acp"]} = ACP.command("gemini")
      assert ACP.cwd("gemini") == "/tmp/gemini-workspace"
    end

    test "every supported runtime speaks ACP unconditionally" do
      for runtime <- ACP.supported_runtimes() do
        assert ACP.enabled?(runtime), "expected #{runtime} to be ACP-enabled"
        assert ACP.enabled?(agent(runtime: runtime, metadata: %{}))
      end
    end

    test "asks_permission? carries a measurement, and defaults to asking" do
      # Measured 2026-08-22 against live agents: claude and codex both send
      # `session/request_permission` per tool call; opencode ran an external
      # `curl` and an `rm -rf` under an ask-everything policy and sent none.
      assert ACP.asks_permission?("claude")
      assert ACP.asks_permission?("codex")
      refute ACP.asks_permission?("opencode")
      assert ACP.runtimes_without_permissions() == ["opencode"]

      # Unmeasured is assumed to ask, which is the safe direction to be wrong
      # in: the first policy written for it gets a loud refusal, not a silent
      # one.
      assert ACP.asks_permission?("somethingelse")
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

  describe "initialize_params/1" do
    test "declares no filesystem or terminal capability by default" do
      params = ACP.initialize_params()

      assert params.clientCapabilities.terminal == false
      assert params.clientCapabilities.fs.readTextFile == false
      assert params.clientCapabilities.fs.writeTextFile == false
    end

    test "a host that services fs/* passes its own capabilities" do
      caps = %{fs: %{readTextFile: true, writeTextFile: false}, terminal: false}
      params = ACP.initialize_params(caps)

      assert params.clientCapabilities == caps
      assert params == Managoat.ACP.Protocol.initialize_params(caps)
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
      # the others, but nothing for us to install: OpenCode.prepare_sandbox/3
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
