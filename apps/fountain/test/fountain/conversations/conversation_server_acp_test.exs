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
    insert_agent(user_id: user.id, runtime: runtime)
  end

  # Starts a server whose turn speaks ACP, with the sprite side wired to this
  # process: every byte written to stdin arrives as `{:wrote, line}`, and the
  # command's ref is ours so tests can feed stdout back.
  defp start_acp_turn(conv) do
    stub_happy_sprite()
    test = self()
    ref = make_ref()

    Mimic.stub(Fountain.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Fountain.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Fountain.Sandbox.Sprites, :close_stdin, fn _c ->
      send(test, :stdin_closed)
      :ok
    end)

    Mimic.stub(Fountain.Sandbox.Sprites, :write_stdin, fn _c, data ->
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

  describe "the decision" do
    test "every shippable runtime speaks ACP; the retired flag routes nothing" do
      user = insert_verified_user()

      for runtime <- ACP.supported_runtimes() do
        agent = insert_agent(user_id: user.id, runtime: runtime)
        assert ACP.enabled?(agent), "expected #{runtime} to be ACP-enabled"
      end

      # Stale metadata from the flag's opt-in/opt-out eras must not resurrect
      # a spawn path that no longer exists.
      assert ACP.enabled?(
               insert_agent(user_id: user.id, runtime: "claude", metadata: %{"acp" => false})
             )
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

    # #724: the refusal used to go to `stderr`, the one stream a protocol
    # client filters out — so an editor (and anyone reading `?streams=acp,stage`)
    # had no way to know the agent was answering on a different model than the
    # one configured. A stage event reaches every surface.
    test "a refused model becomes a stage event, and the turn continues", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      send(pid, {:acp, ref, {:model_rejected, "claude-sonnet-4-6", "Invalid value for model"}})

      # handle_info is async; a sync call flushes the mailbox so the read below
      # sees the event rather than racing it.
      _ = :sys.get_state(pid)

      stage =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.find(&(&1.kind == "stage" and &1.stage == "model"))

      assert stage, "the refusal never reached the transcript as a stage event"
      assert stage.state == "failed"
      assert stage.data =~ "claude-sonnet-4-6"
      assert stage.data =~ "Invalid value for model"

      # And the turn is still alive: a model we could not pin is not worth
      # failing a turn over.
      assert Process.alive?(pid)
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

      Mimic.stub(Fountain.Sandbox.Sprites, :spawn, fn _h, _c, _a, _o ->
        {:ok, %Fountain.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)

      Mimic.stub(Fountain.Sandbox.Sprites, :write_stdin, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      # Nothing should be written into the sandbox filesystem for an ACP turn.
      Mimic.stub(Fountain.Sandbox.Sprites, :write_file, fn _h, path, _contents, _opts ->
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

  # The gemini describes that lived here are gone with #659: gemini is held
  # back from `supported_runtimes/0`, so a gemini agent takes the legacy path
  # and these could only ever assert that. The behaviour they covered did not
  # go away with them —
  #
  #   * launch command and workspace  → `Fountain.Runtimes.ACPTest`
  #     ("the held-back gemini entry still points at the right workspace")
  #   * session/load instead of resume, and the replay discard
  #     → `Fountain.Runtimes.ACP.PeerTest`, driven by an agent advertising
  #       `loadSession` and no `resume`, which is exactly gemini's shape
  #
  # When #659 lifts the block, a gemini conversation-level test belongs here
  # again.
end
