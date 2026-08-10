defmodule Fountain.Conversations.ConversationServerACPTest do
  @moduledoc """
  The ACP path through a real `ConversationServer` (0014 gate 2).

  These are the assertions that cannot be made against the peer alone: which
  binary gets spawned, that stdin is *not* closed at spawn, that protocol bytes
  never reach the transcript, and that a turn ends exactly once even though it
  now has two possible terminators.
  """

  use Fountain.ConversationServerCase

  alias Fountain.Runtimes.ACP

  defp acp_agent(user, runtime \\ "claude") do
    insert_agent(user_id: user.id, runtime: runtime, metadata: %{"acp" => true})
  end

  # Starts a server whose turn speaks ACP, with the sprite side wired to this
  # process: every byte written to stdin arrives as `{:wrote, line}`, and the
  # command's ref is ours so tests can feed stdout back.
  defp start_acp_turn(conv) do
    stub_happy_sprite()
    test = self()
    ref = make_ref()

    # The adapter install runs at provision time. It is `Sprites.cmd/4`
    # returning `{output, exit_code}` — a different arity from the `cmd/3` the
    # permissive harness stubs, so without this the real client is called.
    Mimic.stub(Sprites, :cmd, fn _s, _cmd, _args, _opts -> {"", 0} end)

    Mimic.stub(Sprites, :spawn, fn _s, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %{ref: ref, pid: test}}
    end)

    Mimic.stub(Sprites, :close_stdin, fn _c ->
      send(test, :stdin_closed)
      :ok
    end)

    Mimic.stub(Sprites, :write, fn _c, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")

    # Unconditional teardown. A test that fails an assertion would otherwise
    # skip its own `GenServer.stop`, leaving a server running into the next
    # test — where its peer's next report does DB work against a sandbox
    # connection that has already been checked in, and one real failure
    # becomes four noisy ones.
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {pid, ref}
  end

  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp reply(pid, ref, id, result) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"
    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  # A message crosses three mailboxes: the server takes the stdout chunk and
  # casts it to the peer, the peer acts and reports back, and the server acts on
  # the report. Syncing only the server would assert against a state one hop
  # behind, which is what made these tests pass alone and fail together.
  defp settle(pid) do
    peer = :sys.get_state(pid).acp_peer
    if is_pid(peer) and Process.alive?(peer), do: :sys.get_state(peer)
    _ = :sys.get_state(pid)
    :ok
  end

  defp notify(pid, ref, update) do
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => "sess_1", "update" => update}
      }) <> "\n"

    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  @caps %{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}

  # initialize → session/new → session/prompt, returning the prompt's id so a
  # test can answer it.
  defp drive_to_prompt(pid, ref) do
    %{"id" => init_id, "method" => "initialize"} = next_write()
    reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

    %{"id" => new_id, "method" => "session/new"} = next_write()
    reply(pid, ref, new_id, %{"sessionId" => "sess_1"})

    %{"id" => prompt_id, "method" => "session/prompt"} = next_write()
    settle(pid)
    prompt_id
  end

  describe "the flag" do
    test "is off by default" do
      user = insert_verified_user()
      refute ACP.enabled?(insert_agent(user_id: user.id, runtime: "claude"))
    end

    test "applies to every converted runtime" do
      user = insert_verified_user()

      for runtime <- ACP.supported_runtimes() do
        agent = insert_agent(user_id: user.id, runtime: runtime, metadata: %{"acp" => true})
        assert ACP.enabled?(agent), "expected #{runtime} to be ACP-enabled"
      end

      # All four are converted now, so the flag itself is the only off switch.
      refute ACP.enabled?(insert_agent(user_id: user.id, runtime: "claude"))
    end
  end

  describe "spawn" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      {:ok, conv: conv, pid: pid, ref: ref}
    end

    test "runs the pinned adapter rather than the claude CLI", %{pid: pid} do
      assert_receive {:spawned, cmd, _args, opts}
      assert cmd == ACP.adapter_bin("claude")
      assert opts[:stdin] == true
    end

    test "writes initialize instead of the prompt", %{pid: pid} do
      assert %{"method" => "initialize"} = next_write()
    end

    test "does not close stdin at spawn — it is the return path for the session", %{pid: pid} do
      # The legacy path writes the prompt and closes immediately. Doing that here
      # hangs up on the agent mid-handshake: permission answers and
      # `session/cancel` both travel back up this pipe.
      _ = next_write()
      refute_receive :stdin_closed, 200
    end
  end

  describe "a turn, end to end" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      {:ok, conv: conv, pid: pid, ref: ref}
    end

    test "persists the session id so the next turn can resume it", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      drive_to_prompt(pid, ref)

      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == "sess_1"
    end

    test "protocol chatter never reaches the transcript", %{conv: conv, pid: pid, ref: ref} do
      drive_to_prompt(pid, ref)

      events = Conversations._unsafe_list_log_events(conv.id)

      # A JSON-RPC response to `initialize` is not something a user should find
      # in their conversation.
      refute Enum.any?(events, &(&1.data =~ "agentCapabilities"))
    end

    test "session/update lands as an acp-stream log event", %{conv: conv, pid: pid, ref: ref} do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "the answer"}
      })

      events = Conversations._unsafe_list_log_events(conv.id)
      assert event = Enum.find(events, &(&1.stream == "acp"))
      assert event.data =~ "the answer"
    end

    test "the stop reason ends the turn and closes stdin", %{conv: conv, pid: pid, ref: ref} do
      prompt_id = drive_to_prompt(pid, ref)

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # Closing stdin is what makes the adapter exit.
      assert_receive :stdin_closed
    end

    test "the process exit that follows is a no-op, not a second ending", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      # A turn ends on the prompt response *or* the exit, whichever arrives
      # first, and never waits for both.
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      assert is_nil(turn.exit_code)
    end

    test "a refusal is recorded as a failed turn", %{conv: conv, pid: pid, ref: ref} do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "refusal"})

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
    end

    test "the conversation accepts another prompt afterwards", %{conv: conv, pid: pid, ref: ref} do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2
    end

    test "an adapter that dies mid-handshake still ends the turn", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      # No stop reason will ever arrive. Leaving `current_command` set is the
      # #413 shape: every prompt answered `:busy`, idle reclaim suppressed, and
      # the sprite billing until the lifetime ceiling.
      _ = next_write()
      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end
  end

  describe "turn 2" do
    test "resumes by the persisted id rather than guessing" do
      # The hazard 0014 names: gemini's `--resume` and codex's `--last` re-enter
      # "the most recent conversation in the workspace". ACP names the session.
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: "sess_prior"})

      {pid, ref} = start_acp_turn(conv)

      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      decoded = next_write()
      assert decoded["method"] == "session/resume"
      assert decoded["params"]["sessionId"] == "sess_prior"
    end
  end

  describe "timing" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      {:ok, conv: conv, pid: pid, ref: ref}
    end

    test "the handshake cost is measured per turn", %{conv: conv, pid: pid, ref: ref} do
      # The number gate 2 owes: what a turn pays for `initialize` plus
      # resumption, which the legacy path does not pay at all. Without this
      # emitted per turn, the ADR's "measure it against the current spawn" is
      # something somebody has to remember to do by hand.
      :telemetry.attach(
        "acp-handshake-test",
        [:fountain, :acp, :handshake],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:handshake, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("acp-handshake-test") end)

      %{"id" => init_id, "method" => "initialize"} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      assert_receive {:handshake, %{duration_ms: ms}, meta}
      assert is_integer(ms) and ms >= 0
      assert meta.conversation_id == conv.id
      refute is_nil(meta.turn_id)
    end

    test "the measurement names the session-setup call it paid for", %{
      pid: pid,
      ref: ref
    } do
      # A resume pays a different price from a session/new, and averaging the
      # two together would hide whichever is the problem.
      :telemetry.attach(
        "acp-handshake-mode-test",
        [:fountain, :acp, :handshake],
        fn _e, _m, metadata, test_pid -> send(test_pid, {:method, metadata.method}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("acp-handshake-mode-test") end)

      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      assert_receive {:method, "session/new"}
    end

    test "it is emitted once, not once per message", %{pid: pid, ref: ref} do
      :telemetry.attach(
        "acp-handshake-once-test",
        [:fountain, :acp, :handshake],
        fn _e, _m, _meta, test_pid -> send(test_pid, :handshake) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("acp-handshake-once-test") end)

      drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "hi"}
      })

      assert_receive :handshake
      refute_receive :handshake, 100
    end
  end

  describe "images and mcp servers reach the agent" do
    test "images ride in session/prompt rather than being written to the sandbox" do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)

      stub_happy_sprite()
      test = self()
      ref = make_ref()

      Mimic.stub(Sprites, :cmd, fn _s, _c, _a, _o -> {"", 0} end)
      Mimic.stub(Sprites, :spawn, fn _s, _c, _a, _o -> {:ok, %{ref: ref, pid: test}} end)
      Mimic.stub(Sprites, :close_stdin, fn _c -> :ok end)

      Mimic.stub(Sprites, :write, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      # Nothing should be written into the sandbox filesystem for an ACP turn.
      Mimic.stub(Sprites.Filesystem, :write, fn _fs, path, _contents ->
        send(test, {:fs_write, path})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "look")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      GenServer.call(
        pid,
        {:send_prompt, "and this", [%{media_type: "image/png", data: <<9, 9, 9>>}]}
      )

      settle(pid)

      refute_receive {:fs_write, "/tmp/aod_turn_" <> _}, 100
    end
  end

  # A gemini conversation whose first turn already happened: the session id is
  # persisted, so the server computes mode :continue and the peer resumes.
  # Built fresh rather than restarted, because a second server for a
  # conversation whose sandbox is already `ready` takes the reattach path.
  defp resumed_gemini_turn(shape \\ :bare) do
    user = insert_verified_user()
    agent = acp_agent(user, "gemini")
    conv = insert_conversation(agent: agent, user_id: user.id, runtime: "gemini")
    {:ok, conv} = Conversations.update_conversation(conv, %{runtime_session_id: "gem-1"})
    {pid, ref} = start_acp_turn(conv)

    case shape do
      :with_conv -> {conv, pid, ref}
      :bare -> {pid, ref}
    end
  end

  describe "gemini" do
    setup do
      user = insert_verified_user()
      agent = acp_agent(user, "gemini")
      conv = insert_conversation(agent: agent, user_id: user.id, runtime: "gemini")
      {pid, ref} = start_acp_turn(conv)
      {:ok, conv: conv, pid: pid, ref: ref}
    end

    test "spawns the native flag in the workspace its runtime module git-inits", %{pid: pid} do
      assert_receive {:spawned, cmd, args, opts}
      assert cmd == "gemini"
      assert args == ["--acp"]

      # gemini walks up from cwd looking for a .git. /home/sprite is where the
      # EACCES noise comes from, and Gemini.prepare_sprite/3 prepares exactly
      # this directory.
      assert opts[:dir] == "/tmp/gemini-workspace"

      _ = next_write()
      GenServer.stop(pid)
    end

    test "session/new carries the same cwd the process was spawned in", %{pid: pid, ref: ref} do
      %{"id" => init_id, "method" => "initialize"} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert %{"method" => "session/new", "params" => params} = next_write()
      assert params["cwd"] == "/tmp/gemini-workspace"

      GenServer.stop(pid)
    end

    test "session/new proposes no session id — the agent assigns it", %{pid: pid, ref: ref} do
      # The spec says the *agent* MUST respond with a unique id, and we persist
      # whatever comes back. Proposing one was decoration a stricter agent
      # could reject on schema grounds.
      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert %{"method" => "session/new", "params" => params} = next_write()
      refute Map.has_key?(params, "sessionId")

      GenServer.stop(pid)
    end
  end

  # Separate describe on purpose: these build their own conversation, and the
  # gemini setup above would start a second server writing into the same
  # mailbox, so every assertion would read the wrong connection's traffic.
  describe "gemini, turn 2" do
    test "turn 2 uses session/load, because gemini advertises no resume" do
      {pid, ref} = resumed_gemini_turn()

      %{"id" => init_id} = next_write()
      # Exactly what gemini's dispatcher advertises: loadSession and no
      # sessionCapabilities block at all.
      reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      decoded = next_write()
      assert decoded["method"] == "session/load"
      assert decoded["params"]["sessionId"] == "gem-1"

      GenServer.stop(pid)
    end

    test "the replay gemini sends before session/load returns is discarded" do
      # This is the cost of having no `resume`: the whole conversation arrives
      # again on every turn after the first. We already hold it as log_events,
      # so persisting it would duplicate the transcript into the DB and onto
      # the SSE stream, every turn, for the life of the conversation.
      {conv, pid, ref} = resumed_gemini_turn(:with_conv)

      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
      %{"id" => load_id, "method" => "session/load"} = next_write()

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "REPLAYED HISTORY"}
      })

      reply(pid, ref, load_id, %{})
      %{"method" => "session/prompt"} = next_write()

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "FRESH ANSWER"}
      })

      events = Conversations._unsafe_list_log_events(conv.id)
      acp = Enum.filter(events, &(&1.stream == "acp"))

      assert Enum.any?(acp, &(&1.data =~ "FRESH ANSWER"))
      refute Enum.any?(acp, &(&1.data =~ "REPLAYED HISTORY"))

      GenServer.stop(pid)
    end
  end
end
