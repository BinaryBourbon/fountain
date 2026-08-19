defmodule Fountain.Runtimes.ClaudeTest do
  @moduledoc """
  MCP servers are provisioned into the sandbox (project `.mcp.json` + an
  auto-approve setting) because the ACP session-scoped channel is broken
  upstream (#837). This pins the provisioning shape.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Runtimes.Claude
  alias Fountain.Sandbox

  setup :set_mimic_from_context

  setup do
    Mimic.copy(Fountain.Sandbox)
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

    Mimic.stub(Fountain.Sandbox, :write_file, fn _h, path, body ->
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
end
