defmodule Fountain.Runtimes.ACP.PeerTest do
  @moduledoc """
  Drives a real peer against a scripted agent.

  The sprite side is a Mimic stub on `Sprites.write/2` that forwards whatever
  the peer writes to the test process, so every assertion here is about bytes
  that would actually have gone down the pipe.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Fountain.Runtimes.ACP.Peer

  setup :set_mimic_global

  setup do
    test = self()

    Mimic.stub(Sprites, :write, fn _command, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    {:ok, ref: make_ref(), command: %{ref: :fake, pid: self()}}
  end

  defp start_peer(ctx, opts) do
    {:ok, pid} =
      Peer.start(
        [
          owner: self(),
          command: ctx.command,
          ref: ctx.ref,
          prompt: "do the thing",
          mode: :run,
          session_id: nil,
          cwd: "/work",
          images: [],
          mcp_servers: []
        ]
        |> Keyword.merge(opts)
      )

    pid
  end

  # Receive the next thing the peer wrote, decoded.
  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp send_response(pid, id, result) do
    Peer.stdout(pid, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n")
  end

  defp update_line(update) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s1", "update" => update}
    }) <> "\n"
  end

  defp caps(extra \\ %{}) do
    Map.merge(%{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}, extra)
  end

  describe "handshake" do
    test "the first thing on the wire is initialize", ctx do
      start_peer(ctx, [])

      assert %{"method" => "initialize", "id" => _} = next_write()
    end

    test "declares no filesystem or terminal capabilities", ctx do
      # 0016 makes servicing fs/* and terminal/* its own gate. Gate 2 asks for
      # nothing, so a well-behaved adapter never calls them.
      start_peer(ctx, [])

      assert %{"params" => params} = next_write()
      assert params["clientCapabilities"]["terminal"] == false
      assert params["clientCapabilities"]["fs"]["readTextFile"] == false
      assert params["clientCapabilities"]["fs"]["writeTextFile"] == false
    end

    test "reports the handshake cost, labelled with the call it is about to make", ctx do
      pid = start_peer(ctx, [])
      %{"id" => id} = next_write()

      send_response(pid, id, %{"agentCapabilities" => caps()})

      assert_receive {:acp, _ref, {:handshake_ms, ms, "session/new"}}
      assert is_integer(ms) and ms >= 0
    end
  end

  describe "turn 1 — session/new" do
    test "creates a session, reports the id, then prompts", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/new", "id" => new_id, "params" => params} = next_write()
      assert params["cwd"] == "/work"

      send_response(pid, new_id, %{"sessionId" => "sess_abc"})

      assert_receive {:acp, _ref, {:session, "sess_abc"}}

      assert %{"method" => "session/prompt", "params" => prompt_params} = next_write()
      assert prompt_params["sessionId"] == "sess_abc"
      assert [%{"type" => "text", "text" => "do the thing"}] = prompt_params["prompt"]
    end

    test "a session response with no id fails the turn rather than prompting blind", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()

      send_response(pid, new_id, %{})

      assert_receive {:acp, _ref, {:failed, {:acp_no_session_id, _}}}
    end
  end

  describe "turn N — resumption" do
    test "prefers session/resume when the agent advertises it", ctx do
      # This is the whole reason Claude is the gate 2 runtime: resume restores
      # context without replaying, so a turn costs a handshake and nothing else.
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/resume", "params" => params} = next_write()
      assert params["sessionId"] == "sess_abc"
    end

    test "falls back to session/load when resume is not advertised", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert %{"method" => "session/load"} = next_write()
    end

    test "the handshake measurement names the expensive path when it takes it", ctx do
      # A load pays for a full history replay and a resume does not. Reporting
      # both as "a resume" would average away the only number that would tell us
      # a pinned adapter had stopped advertising `sessionCapabilities.resume`.
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert_receive {:acp, _ref, {:handshake_ms, _ms, "session/load"}}
    end

    test "an agent that can do neither fails the turn instead of starting a second session",
         ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{}})

      assert_receive {:acp, _ref, {:failed, :acp_agent_cannot_resume}}
    end

    test "continue with no session id is a contradiction and fails loudly", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: nil)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert_receive {:acp, _ref, {:failed, :acp_resume_without_session_id}}
    end
  end

  describe "replay discard" do
    test "updates arriving during session/load are dropped, and later ones are not", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id} = next_write()

      # The replay: history we already hold as log_events.
      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "OLD TURN"}
        })
      )

      refute_receive {:acp, _, {:lines, _, _}}, 100

      send_response(pid, load_id, %{})
      %{"method" => "session/prompt"} = next_write()

      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "NEW"}
        })
      )

      assert_receive {:acp, _ref, {:lines, "acp", data}}
      assert data =~ "NEW"
      refute data =~ "OLD TURN"
    end

    test "session/resume never enters replay-discard, so nothing is lost", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "sess_abc")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => resume_id} = next_write()
      send_response(pid, resume_id, %{})
      %{"method" => "session/prompt"} = next_write()

      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "kept"}
        })
      )

      assert_receive {:acp, _ref, {:lines, "acp", data}}
      assert data =~ "kept"
    end
  end

  describe "the turn's end" do
    test "a stop reason ends the turn", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()

      send_response(pid, prompt_id, %{"stopReason" => "end_turn"})

      assert_receive {:acp, _ref, {:done, "end_turn"}}
    end

    test "an error response fails the turn", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "error" => %{"code" => -32_000, "message" => "bad key"}
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :initialize, %{"message" => "bad key"}}}}
    end

    test "a stdin write failure fails the turn rather than exiting the peer", ctx do
      # #603: Sprites.write is a bare GenServer.call underneath, and the command
      # process stops :normal the moment the runtime's exit frame arrives — so a
      # write landing after that exits the *caller* with the call wrapped
      # alongside the reason. SpriteStdin turns that into an error; the peer
      # must report it, because a peer that dies silently leaves a turn with no
      # terminator at all.
      Mimic.stub(Sprites, :write, fn _c, _d ->
        exit({:normal, {GenServer, :call, [self(), :write, 5_000]}})
      end)

      start_peer(ctx, [])

      assert_receive {:acp, _ref, {:failed, {:acp_write_failed, :command_exited}}}
    end
  end

  describe "agent → client requests" do
    test "a permission request is auto-allowed, matching the legacy bypass flags", ctx do
      # Gate 2 keeps parity with `--dangerously-skip-permissions`: answering is
      # mandatory (a blocked agent is a turn in flight, which disarms idle
      # reclaim), and gate 3 is where the answer starts coming from a policy.
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      _prompt = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 99,
          "method" => "session/request_permission",
          "params" => %{
            "options" => [
              %{"optionId" => "no", "kind" => "reject_once"},
              %{"optionId" => "yes", "kind" => "allow_always"}
            ]
          }
        }) <> "\n"
      )

      assert %{"id" => 99, "result" => %{"outcome" => outcome}} = next_write()
      assert outcome["outcome"] == "selected"
      assert outcome["optionId"] == "yes"
    end

    test "an fs/* request is refused, not ignored", ctx do
      # Silence would block the agent forever. We declared no fs capability, so
      # the honest answer is method-not-found.
      pid = start_peer(ctx, [])
      _init = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "method" => "fs/read_text_file"}) <> "\n"
      )

      assert %{"id" => 5, "error" => %{"code" => -32_601}} = next_write()
    end
  end

  describe "noise" do
    test "a non-JSON line is persisted as ordinary output", ctx do
      pid = start_peer(ctx, [])
      _init = next_write()

      Peer.stdout(pid, "npm warn deprecated punycode@2.3.1\n")

      assert_receive {:acp, _ref, {:lines, "stdout", data}}
      assert data =~ "npm warn"
    end
  end

  describe "images" do
    test "ride along in session/prompt as base64 content blocks", ctx do
      # The legacy path writes the bytes into the sandbox and appends the paths
      # to the prompt, hoping the model reaches for its Read tool. ACP carries
      # them in the prompt itself.
      pid = start_peer(ctx, images: [%{media_type: "image/png", data: <<1, 2, 3>>}])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})

      assert %{"method" => "session/prompt", "params" => params} = next_write()

      assert [
               %{"type" => "text", "text" => "do the thing"},
               %{"type" => "image", "mimeType" => "image/png", "data" => data}
             ] = params["prompt"]

      assert Base.decode64!(data) == <<1, 2, 3>>
    end

    test "a prompt with no images is text only", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})

      assert %{"params" => %{"prompt" => [%{"type" => "text"}]}} = next_write()
    end
  end

  describe "mcp servers" do
    @servers [%{name: "files", command: "mcp-files", env: [%{name: "K", value: "v"}]}]

    test "are sent with session/new", ctx do
      pid = start_peer(ctx, mcp_servers: @servers)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/new", "params" => params} = next_write()
      assert [%{"name" => "files", "command" => "mcp-files"}] = params["mcpServers"]
    end

    test "are re-sent on resume, not assumed to have survived", ctx do
      # The adapter snapshots {cwd, mcpServers} per session and tears the
      # session down when they change, so omitting them on resume would read as
      # "the client removed every MCP server".
      pid = start_peer(ctx, mode: :continue, session_id: "s1", mcp_servers: @servers)
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})

      assert %{"method" => "session/resume", "params" => params} = next_write()
      assert [%{"name" => "files"}] = params["mcpServers"]
    end
  end

  test "the peer dies with its owner", ctx do
    owner = spawn(fn -> receive do: (:never -> :ok) end)

    {:ok, pid} =
      Peer.start(
        owner: owner,
        command: ctx.command,
        ref: ctx.ref,
        prompt: "p",
        mode: :run,
        session_id: nil,
        cwd: "/work",
        images: [],
        mcp_servers: []
      )

    monitor = Process.monitor(pid)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end
end
