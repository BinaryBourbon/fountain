defmodule Managoat.Runtimes.ClaudeTest do
  @moduledoc """
  MCP servers are provisioned into the sandbox (project `.mcp.json` + an
  auto-approve setting) because the ACP session-scoped channel is broken
  upstream (#837). This pins the provisioning shape.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Claude
  alias Managoat.Sandbox

  setup :set_mimic_from_context

  setup do
    Mimic.copy(Managoat.Sandbox)
    handle = %Sandbox.Handle{provider: :fake, name: "sb"}
    {:ok, handle: handle}
  end

  test "no MCP servers writes nothing", %{handle: handle} do
    Mimic.reject(&Sandbox.write_file/3)
    Mimic.reject(&Sandbox.write_file/4)
    assert Claude.write_config(handle, %{mcp_servers: %{}}) == :ok
    assert Claude.write_config(handle, %{mcp_servers: nil}) == :ok
    assert Claude.write_config(handle, nil) == :ok
  end

  test "MCP servers are written as project .mcp.json plus an auto-approve setting", %{
    handle: handle
  } do
    test = self()

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, path, body ->
      send(test, {:wrote, path, body})
      :ok
    end)

    mcp = %{
      "fs" => %{
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
      }
    }

    assert Claude.write_config(handle, %{mcp_servers: mcp}) == :ok

    assert_receive {:wrote, "/home/sprite/.mcp.json", mcp_json}
    assert %{"mcpServers" => %{"fs" => %{"command" => "npx"}}} = Jason.decode!(mcp_json)

    assert_receive {:wrote, "/home/sprite/.claude/settings.json", settings}
    assert %{"enableAllProjectMcpServers" => true} = Jason.decode!(settings)
  end

  test "a transient write error is retried, then the config lands", %{handle: handle} do
    # The first filesystem call into a freshly created sprite timed out once
    # in prod and, with no retry, failed the whole provision. Both writes are
    # idempotent, so they go through Managoat.Sandbox.Retry.
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
        _ -> :ok
      end
    end)

    assert Claude.write_config(handle, %{mcp_servers: %{"fs" => %{"command" => "npx"}}}) == :ok
    assert Agent.get(calls, & &1) == 3
  end

  test "a write that keeps failing is a tagged error, not a crash", %{handle: handle} do
    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body ->
      {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
    end)

    assert {:error, {:runtime_config, "/home/sprite/.mcp.json", {:unavailable, _}}} =
             Claude.write_config(handle, %{mcp_servers: %{"fs" => %{"command" => "npx"}}})
  end

  describe "default_env/2" do
    test "prefers the oauth token over the api key" do
      env =
        Claude.default_env(nil, %{
          claude_code_oauth_token: "oauth-token",
          anthropic_api_key: "api-key"
        })

      assert env == [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}]
    end

    test "falls back to the api key when there is no oauth token" do
      env = Claude.default_env(nil, %{anthropic_api_key: "api-key"})

      assert env == [{"ANTHROPIC_API_KEY", "api-key"}]
    end

    test "is empty when neither credential is on file" do
      assert Claude.default_env(nil, %{}) == []
    end
  end

  describe "fall_back_to_api_key/2 (#655)" do
    test "swaps the oauth token for the api key when one is on file" do
      env = [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}, {"OTHER_VAR", "x"}]

      result = Claude.fall_back_to_api_key(env, %{anthropic_api_key: "api-key"})

      assert {"ANTHROPIC_API_KEY", "api-key"} in result
      refute List.keymember?(result, "CLAUDE_CODE_OAUTH_TOKEN", 0)
      assert {"OTHER_VAR", "x"} in result
    end

    test "leaves the env untouched when no api key is on file" do
      env = [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}]

      assert Claude.fall_back_to_api_key(env, %{}) == env
    end

    test "does not duplicate an api key entry the env already carries" do
      env = [
        {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"},
        {"ANTHROPIC_API_KEY", "stale-key"}
      ]

      result = Claude.fall_back_to_api_key(env, %{anthropic_api_key: "fresh-key"})

      assert Enum.count(result, fn {k, _v} -> k == "ANTHROPIC_API_KEY" end) == 1
      assert {"ANTHROPIC_API_KEY", "fresh-key"} in result
    end
  end
end
