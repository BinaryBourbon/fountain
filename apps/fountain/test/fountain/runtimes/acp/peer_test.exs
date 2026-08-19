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

    Mimic.stub(Fountain.Sandbox.Sprites, :write_stdin, fn _command, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    {:ok, ref: make_ref(), command: %Fountain.Sandbox.Command{provider: :sprites, ref: :fake}}
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

      assert %{"method" => "session/prompt", "id" => prompt_id, "params" => prompt_params} =
               next_write()

      assert prompt_params["sessionId"] == "sess_abc"
      assert [%{"type" => "text", "text" => "do the thing"}] = prompt_params["prompt"]

      # The id is reported the moment the prompt is on the wire: it is what a
      # reattach after a restart resumes the turn by.
      assert_receive {:acp, _ref, {:prompt_sent, ^prompt_id}}
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

    test "a replay that lands after the load response is still discarded", ctx do
      # #657: gemini streams its replay as a floating promise, so `session/load`
      # answers *before* replaying. Measured against a live agent — closing the
      # window on the response duplicated the whole transcript.
      pid =
        start_peer(ctx,
          mode: :continue,
          session_id: "sess_abc",
          replay_quiet_ms: 40,
          replay_max_ms: 2_000
        )

      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id} = next_write()

      send_response(pid, load_id, %{})

      # Late replay, in two bursts, each of which pushes the quiet period out.
      for text <- ["OLD ONE", "OLD TWO"] do
        Peer.stdout(
          pid,
          update_line(%{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => text}
          })
        )

        Process.sleep(20)
      end

      refute_receive {:acp, _, {:lines, _, _}}, 20

      # Only once the stream goes quiet does the turn's own prompt go out.
      assert %{"method" => "session/prompt"} = next_write()

      Peer.stdout(
        pid,
        update_line(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "NEW"}
        })
      )

      assert_receive {:acp, _ref, {:lines, "acp", data}}
      assert data =~ "NEW"
      refute data =~ "OLD"
    end

    test "a replay that never goes quiet still prompts, rather than holding the turn open", ctx do
      # An unbounded wait would be the #413 shape: a turn in flight disarms idle
      # reclaim, so a chatty agent could bill a sprite to its ceiling.
      pid =
        start_peer(ctx,
          mode: :continue,
          session_id: "sess_abc",
          replay_quiet_ms: 30,
          replay_max_ms: 60
        )

      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id} = next_write()
      send_response(pid, load_id, %{})

      noisy = fn ->
        Peer.stdout(
          pid,
          update_line(%{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "chatter"}
          })
        )
      end

      for _ <- 1..12 do
        noisy.()
        Process.sleep(10)
      end

      assert %{"method" => "session/prompt"} = next_write()
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

      assert_receive {:acp, _ref, {:done, "end_turn", nil}}
    end

    test "the response's usage rides along, normalised (#827)", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})
      %{"id" => prompt_id} = next_write()

      send_response(pid, prompt_id, %{
        "stopReason" => "end_turn",
        "usage" => %{
          "inputTokens" => 1200,
          "outputTokens" => 340,
          "cachedReadTokens" => 900,
          "cachedWriteTokens" => 0,
          "totalTokens" => 2440
        }
      })

      assert_receive {:acp, _ref,
                      {:done, "end_turn",
                       %{
                         "input" => 1200,
                         "output" => 340,
                         "cache_read" => 900,
                         "cache_write" => 0
                       }}}
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
      # #603: the SDK write is a bare GenServer.call underneath, and the command
      # process stops :normal the moment the runtime's exit frame arrives. The
      # adapter's write_stdin/2 turns that into {:error, :command_exited}; the
      # peer must report it, because a peer that dies silently leaves a turn
      # with no terminator at all. (The exit-to-error catch itself is pinned in
      # the adapter's own tests.)
      Mimic.stub(Fountain.Sandbox.Sprites, :write_stdin, fn _c, _d ->
        {:error, :command_exited}
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

  describe "model selection" do
    # ACP carries no model in session/new, so without this the runtime's own
    # default silently wins over the model the tenant configured — and for a
    # multi-provider runtime that is the entire configuration.
    defp caps_with_model_option,
      do: %{"sessionId" => "s", "configOptions" => [%{"id" => "model"}]}

    test "pins the configured model when the agent advertises the option", ctx do
      pid = start_peer(ctx, model: "claude-sonnet-4-6")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())

      assert %{"method" => "session/set_config_option", "id" => set_id, "params" => params} =
               next_write()

      assert params["configId"] == "model"
      assert params["value"] == "claude-sonnet-4-6"
      assert params["sessionId"] == "s"

      send_response(pid, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
    end

    test "says so in the transcript when the runtime has no model option", ctx do
      # Silently running someone else's model is the failure mode this whole
      # campaign keeps turning up. Not fatal, but not invisible either.
      pid = start_peer(ctx, model: "gemini-2.5-pro")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, %{"sessionId" => "s"})

      assert_receive {:acp, _ref, {:lines, "stderr", msg}}
      assert msg =~ "does not expose model selection"
      assert msg =~ "gemini-2.5-pro"

      assert %{"method" => "session/prompt"} = next_write()
    end

    test "a refused model is reported but does not fail the turn", ctx do
      pid = start_peer(ctx, model: "not-a-real-model")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())
      %{"id" => set_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => set_id,
          "error" => %{"code" => -32_602, "message" => "Invalid value for config option model"}
        }) <> "\n"
      )

      # Reported as a structured event, not an stderr line: stderr is the one
      # stream `?streams=acp,stage` and `fountain acp` both drop, so the
      # warning was invisible to protocol clients (#724).
      assert_receive {:acp, _ref, {:model_rejected, "not-a-real-model", detail}}
      assert detail =~ "Invalid value for config option model"

      # The turn still runs.
      assert %{"method" => "session/prompt"} = next_write()
      refute_receive {:acp, _ref, {:failed, _}}, 100
    end

    test "no configured model means no round trip at all", ctx do
      pid = start_peer(ctx, [])
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()
      send_response(pid, new_id, caps_with_model_option())

      assert %{"method" => "session/prompt"} = next_write()
    end
  end

  describe "authentication on demand" do
    # gemini opens a session from ambient credentials but answers session/load
    # with -32000 "Authentication required", so every turn after the first
    # failed outright until the peer learned to authenticate. Measured live on
    # 2026-08-10; the method ids below are gemini's own.
    @gemini_auth [
      %{"id" => "oauth-personal", "name" => "Log in with Google"},
      %{"id" => "gemini-api-key", "name" => "Gemini API key", "_meta" => %{"api-key" => %{}}},
      %{"id" => "vertex-ai", "name" => "Vertex AI"}
    ]

    defp init_with_auth(pid, methods) do
      %{"id" => init_id} = next_write()

      send_response(pid, init_id, %{
        "agentCapabilities" => %{"loadSession" => true},
        "authMethods" => methods
      })

      init_id
    end

    defp refuse(pid, id, message) do
      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_000, "message" => message}
        }) <> "\n"
      )
    end

    test "authenticates before opening a session, not after being refused", ctx do
      # Reactive was too late. Gemini opens a session from ambient credentials
      # without being told a method, but does not *persist* one — the next
      # turn's session/load then answers "No previous sessions found for this
      # project", so the retry authenticates correctly and finds nothing.
      # Measured live 2026-08-10.
      pid = start_peer(ctx, [])
      init_with_auth(pid, @gemini_auth)

      assert %{"method" => "authenticate", "id" => auth_id, "params" => params} = next_write()

      # The api-key method, not the OAuth one: a headless sandbox can never
      # complete an interactive Google login, and gemini lists oauth first.
      assert params["methodId"] == "gemini-api-key"

      send_response(pid, auth_id, %{})

      # Only then is the session opened.
      assert %{"method" => "session/new"} = next_write()
    end

    test "an agent advertising no methods is never sent authenticate", ctx do
      # claude's adapter returns authMethods: [] (measured), so this must be a
      # complete no-op for it rather than a guessed method.
      pid = start_peer(ctx, [])
      init_with_auth(pid, [])

      assert %{"method" => "session/new"} = next_write()
    end

    test "never picks a method that is not an api key", ctx do
      # opencode advertises exactly ["opencode-login"], an interactive flow a
      # headless sandbox cannot complete. A first-in-the-list fallback picked
      # it and got away with it; an agent that *blocked* on that login would
      # leave the turn in flight forever, which disarms idle reclaim.
      pid = start_peer(ctx, [])
      init_with_auth(pid, [%{"id" => "opencode-login", "name" => "Log in to OpenCode"}])

      assert %{"method" => "session/new"} = next_write()
    end

    test "does not authenticate a second time", ctx do
      # An agent that refuses after we have already authenticated is refusing
      # for a reason authentication will not fix; looping would hold the turn
      # open indefinitely.
      pid = start_peer(ctx, mode: :continue, session_id: "gem-1")
      init_with_auth(pid, @gemini_auth)

      %{"id" => auth_id, "method" => "authenticate"} = next_write()
      send_response(pid, auth_id, %{})
      %{"id" => load_id} = next_write()
      refuse(pid, load_id, "Authentication required")

      assert_receive {:acp, _ref, {:failed, {:acp_error, :load_session, _}}}
    end

    test "the reactive backstop still covers an agent that advertised nothing", ctx do
      # Eager covers everything measured; this covers being wrong about that,
      # once, rather than failing the turn outright.
      pid = start_peer(ctx, mode: :continue, session_id: "gem-1")

      %{"id" => init_id} = next_write()

      send_response(pid, init_id, %{
        "agentCapabilities" => %{"loadSession" => true},
        "authMethods" => []
      })

      %{"id" => load_id, "method" => "session/load"} = next_write()
      refuse(pid, load_id, "Authentication required")

      # Nothing to pick, so it fails rather than inventing a method.
      assert_receive {:acp, _ref, {:failed, {:acp_error, :load_session, _}}}
    end

    test "a non-auth error is not retried as an auth problem", ctx do
      pid = start_peer(ctx, mode: :continue, session_id: "gem-1")
      init_with_auth(pid, @gemini_auth)

      %{"id" => auth_id, "method" => "authenticate"} = next_write()
      send_response(pid, auth_id, %{})
      %{"id" => load_id} = next_write()

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => load_id,
          "error" => %{"code" => -32_602, "message" => "Session not found"}
        }) <> "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :load_session, _}}}
    end
  end

  describe "model selection, second shape" do
    test "uses session/set_model when the agent advertises models", ctx do
      # gemini exposes `models` in the session response and implements ACP's
      # own session/set_model; claude's adapter exposes `configOptions` and
      # takes session/set_config_option. Neither is a superset of the other.
      pid = start_peer(ctx, model: "gemini-flash-latest")
      %{"id" => init_id} = next_write()
      send_response(pid, init_id, %{"agentCapabilities" => caps()})
      %{"id" => new_id} = next_write()

      send_response(pid, new_id, %{
        "sessionId" => "s",
        "models" => %{"availableModels" => [], "currentModelId" => "x"}
      })

      assert %{"method" => "session/set_model", "id" => set_id, "params" => params} = next_write()
      assert params["modelId"] == "gemini-flash-latest"
      assert params["sessionId"] == "s"

      send_response(pid, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
    end
  end

  describe "attach — resuming a turn already in flight" do
    # A deploy restarts the peer while the adapter, a detachable session in the
    # sprite, keeps running with `session/prompt` outstanding. The new peer is
    # handed the prompt's id and joins the stream: no handshake, replayed
    # history ignored, live requests answered, the prompt's answer ends it.

    defp attached_peer(ctx, prompt_id \\ 4) do
      start_peer(ctx, mode: :continue, session_id: "sess_live", attach: prompt_id)
    end

    test "writes nothing on start — no initialize, no session call, no second prompt", ctx do
      pid = attached_peer(ctx)
      _ = :sys.get_state(pid)
      refute_receive {:wrote, _}, 100
    end

    test "the replayed handshake — responses and a model refusal — is ignored", ctx do
      pid = attached_peer(ctx, 4)

      # initialize, session/resume, then the set_config_option the previous
      # peer already reported as a `model failed` stage event.
      send_response(pid, 1, %{"agentCapabilities" => caps()})
      send_response(pid, 2, %{"configOptions" => [%{"id" => "model"}]})

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "error" => %{"code" => -32_603, "data" => %{"details" => "Invalid value"}}
        }) <> "\n"
      )

      _ = :sys.get_state(pid)
      refute_received {:acp, _, {:failed, _}}
      refute_received {:acp, _, {:done, _, _}}
      refute_received {:acp, _, {:model_rejected, _, _}}
    end

    test "a live permission request is answered — the reason the turn used to hang", ctx do
      pid = attached_peer(ctx)

      Peer.stdout(
        pid,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "session/request_permission",
          "params" => %{"options" => [%{"optionId" => "allow", "kind" => "allow_once"}]}
        }) <> "\n"
      )

      assert %{"id" => 5, "result" => %{"outcome" => %{"optionId" => "allow"}}} = next_write()
    end

    test "updates are relayed for persistence", ctx do
      pid = attached_peer(ctx)
      Peer.stdout(pid, update_line(%{"sessionUpdate" => "agent_message_chunk"}))
      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ "agent_message_chunk"
    end

    test "the response to the prompt id ends the turn; an error to it fails the turn", ctx do
      pid = attached_peer(ctx, 4)
      send_response(pid, 4, %{"stopReason" => "end_turn"})
      assert_receive {:acp, _ref, {:done, "end_turn", nil}}

      pid2 = attached_peer(ctx, 7)

      Peer.stdout(
        pid2,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "error" => %{"message" => "gone"}}) <>
          "\n"
      )

      assert_receive {:acp, _ref, {:failed, {:acp_error, :prompt, %{"message" => "gone"}}}}
    end

    test "cancel still reaches the agent, addressed to the live session", ctx do
      pid = attached_peer(ctx)
      Peer.cancel(pid)

      assert %{"method" => "session/cancel", "params" => %{"sessionId" => "sess_live"}} =
               next_write()
    end

    test "the replay's partial first line is dropped, not persisted as noise", ctx do
      # Sprites replays the tail of its buffer, which starts wherever it starts.
      pid = attached_peer(ctx)
      good = update_line(%{"sessionUpdate" => "usage_update", "used" => 1})
      Peer.stdout(pid, ~s(le":"garbage"}}}\n) <> good)

      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ "usage_update"
      refute_receive {:acp, _ref, {:lines, "stdout", _}}, 100
    end

    test "a first chunk that opens a JSON line is kept whole", ctx do
      pid = attached_peer(ctx)
      Peer.stdout(pid, update_line(%{"sessionUpdate" => "usage_update", "used" => 2}))
      assert_receive {:acp, _ref, {:lines, "acp", line}}
      assert line =~ ~s("used":2)
    end

    test "a first fragment with no newline yet is held until the line boundary arrives", ctx do
      pid = attached_peer(ctx)
      Peer.stdout(pid, "tail-of-a-line")
      Peer.stdout(pid, "-still-going\n" <> update_line(%{"sessionUpdate" => "usage_update"}))
      assert_receive {:acp, _ref, {:lines, "acp", _}}
      refute_receive {:acp, _ref, {:lines, "stdout", _}}, 100
    end
  end
end
