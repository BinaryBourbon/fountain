defmodule Fountain.Runtimes.ACP.PeerMcpTest do
  @moduledoc """
  The ACP peer must deliver the agent's configured MCP servers to the agent in
  `session/new` (and on resume). This is the Fountain half of #837: it proves
  Fountain emits a correct, non-empty `mcpServers` on the wire — the drop that
  bug tracks is downstream, in the agent adapter (`claude-agent-acp`), which
  receives this and fails to launch stdio servers. Keep this green so a
  regression on *our* side is caught separately from the upstream issue.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Fountain.Runtimes.ACP.Peer

  setup :set_mimic_global

  setup do
    test = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _command, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    {:ok, ref: make_ref(), command: %Managoat.Sandbox.Command{provider: :sprites, ref: :fake}}
  end

  @fs %{name: "fs", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "."]}

  defp start(ctx, opts) do
    {:ok, pid} =
      Peer.start(
        Keyword.merge(
          [
            owner: self(),
            command: ctx.command,
            ref: ctx.ref,
            prompt: "hi",
            mode: :run,
            session_id: nil,
            cwd: "/home/sprite",
            images: [],
            mcp_servers: [@fs]
          ],
          opts
        )
      )

    pid
  end

  defp write, do: assert_receive({:wrote, l}, 1_000) && Jason.decode!(l)

  defp ack_init(pid) do
    %{"id" => id, "method" => "initialize"} = write()

    Peer.stdout(
      pid,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"agentCapabilities" => %{}}}) <>
        "\n"
    )
  end

  test "session/new carries the configured MCP servers", ctx do
    pid = start(ctx, mode: :run)
    ack_init(pid)

    frame = write()
    assert frame["method"] == "session/new"

    assert frame["params"]["mcpServers"] == [
             %{
               "name" => "fs",
               "command" => "npx",
               "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
             }
           ]
  end

  test "an agent with no MCP servers sends an empty list, not a missing key", ctx do
    pid = start(ctx, mode: :run, mcp_servers: [])
    ack_init(pid)

    frame = write()
    assert frame["method"] == "session/new"
    assert frame["params"]["mcpServers"] == []
  end
end
