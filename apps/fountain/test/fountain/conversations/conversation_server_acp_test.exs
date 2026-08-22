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
  #
  # `credentials` overrides `stub_happy_sprite/1`'s empty
  # `InferenceCredentials.decrypted_for_user/2` stub — set after, since
  # `stub_happy_sprite/1` would otherwise clobber it back to `%{}`.
  #
  # `runtime` matches `start_server/2`'s own default (`FakeRuntime`) so every
  # existing call site is unaffected; a test asserting on real runtime-module
  # behaviour (credential env mapping, #655) passes the real module — `conv`'s
  # `runtime` string alone is not enough, since `state.runtime_module` is
  # this arg, independent of it (see `start_server/2`).
  defp start_acp_turn(conv, credentials \\ %{}, runtime \\ Fountain.Test.FakeRuntime) do
    stub_happy_sprite()

    Mimic.stub(Fountain.InferenceCredentials, :decrypted_for_user, fn _u, _k ->
      {:ok, credentials}
    end)

    # Turn 1 fires title generation, which is a live HTTPS call to the model
    # provider. Every other test here leaves `credentials` empty, so it used to
    # bail at `:no_credentials` before reaching the network — the moment a test
    # supplies a key-shaped credential it dials out for real. Nothing in this
    # file asserts on titles, so stub the boundary rather than let an offline
    # or egress-restricted runner decide how long the call takes to fail.
    Mimic.stub(Fountain.Conversations.TitleGenerator, :generate, fn _prompt, _creds ->
      {:error, :stubbed_in_test}
    end)

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

    {pid, _mon, :alive} = start_server(conv, initial_prompt: "first", runtime: runtime)

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
  #
  # The peer is stopped by the server the moment it reports `{:done, _}`, so
  # between reading `acp_peer` and syncing on it the peer may already be gone
  # (a `noproc` exit from `:sys.get_state/1`, seen in CI on 2026-08-17). That
  # is the state we wanted anyway — the report was handled — so a dead peer
  # is not a failure here.
  defp settle(pid) do
    peer = :sys.get_state(pid).acp_peer

    if is_pid(peer) do
      try do
        _ = :sys.get_state(peer)
      catch
        :exit, _ -> :ok
      end
    end

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

    test "persists the prompt's JSON-RPC id so a restart can resume the turn", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.acp_prompt_id == prompt_id
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
      prompt_id = drive_to_prompt(pid, ref)

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

      # Finish it. A test that leaves a turn in flight leaves a live peer and a
      # busy server behind, and the neighbours in this file are timing
      # sensitive enough to have earned `settle/1`.
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end

    test "the response's usage lands on the turn and the conversation's sums (#827)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      reply(pid, ref, prompt_id, %{
        "stopReason" => "end_turn",
        "usage" => %{"inputTokens" => 100, "outputTokens" => 25, "totalTokens" => 125}
      })

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      assert turn.usage == %{"input" => 100, "output" => 25}

      conv = Conversations._unsafe_get_conversation!(conv.id)
      assert conv.usage_input_tokens == 100
      assert conv.usage_output_tokens == 25
    end

    test "a response without usage leaves the turn's usage nil", %{conv: conv, pid: pid, ref: ref} do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert [%{usage: nil}] = Conversations._unsafe_list_turns(conv.id)
      assert %{usage_input_tokens: 0} = Conversations._unsafe_get_conversation!(conv.id)
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

  describe "org-disallowed oauth (#655)" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {:ok, conv: conv}
    end

    defp oauth_error_reply(pid, ref, id) do
      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32_603,
            "message" => "Internal error",
            "data" => %{
              "details" =>
                "oauth_org_not_allowed: Your organization has disabled Claude subscription access"
            }
          }
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)
    end

    defp failed_turn_stage(conv_id) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.find(&(&1.kind == "stage" and &1.stage == "turn" and &1.state == "failed"))
    end

    test "falls back to the api key for the rest of the conversation, when one is on file", %{
      conv: conv
    } do
      {pid, ref} =
        start_acp_turn(
          conv,
          %{claude_code_oauth_token: "oauth-token", anthropic_api_key: "api-key"},
          Fountain.Runtimes.Claude
        )

      # Drain turn 1's own spawn message — otherwise the `assert_receive` below
      # would match this stale one (still carrying the doomed oauth token)
      # rather than turn 2's fresh spawn.
      assert_receive {:spawned, _cmd, _args, _turn_1_opts}

      prompt_id = drive_to_prompt(pid, ref)
      oauth_error_reply(pid, ref, prompt_id)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"

      stage = failed_turn_stage(conv.id)
      assert stage.data =~ "Switched to the Anthropic API key"

      # The conversation is usable again — the next turn spawns with the
      # fallback credential, not the one the org already refused.
      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      assert_receive {:spawned, _cmd, _args, opts}

      env = Keyword.fetch!(opts, :env)
      assert {"ANTHROPIC_API_KEY", "api-key"} in env
      refute List.keymember?(env, "CLAUDE_CODE_OAUTH_TOKEN", 0)
    end

    test "the swapped-in api key is registered for output redaction", %{conv: conv} do
      # Only `build_sprite_env/5` registers secrets with the redaction table,
      # and the fallback never goes through it — so without an explicit
      # registration the one credential this fix puts into the sandbox is the
      # one credential that would print in plaintext into `log_events`. The
      # refused OAuth token stays registered too: it is still in the sprite's
      # `.env` on disk until a wake rewrites the file.
      {pid, ref} =
        start_acp_turn(
          conv,
          %{
            claude_code_oauth_token: "oauth-token-long-enough",
            anthropic_api_key: "api-key-long-enough"
          },
          Fountain.Runtimes.Claude
        )

      prompt_id = drive_to_prompt(pid, ref)
      oauth_error_reply(pid, ref, prompt_id)

      registered = Fountain.Conversations.Redaction.lookup(conv.id)
      assert "api-key-long-enough" in registered
      assert "oauth-token-long-enough" in registered
    end

    test "says so plainly when there is no api key to fall back to", %{conv: conv} do
      {pid, ref} =
        start_acp_turn(conv, %{claude_code_oauth_token: "oauth-token"}, Fountain.Runtimes.Claude)

      prompt_id = drive_to_prompt(pid, ref)
      oauth_error_reply(pid, ref, prompt_id)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"

      stage = failed_turn_stage(conv.id)
      assert stage.data =~ "no Anthropic API key is on file"
    end
  end

  describe "turn 2" do
    test "resumes by the persisted id rather than guessing" do
      # The hazard 0014 names: gemini's `--resume` and codex's `--last` re-enter
      # "the most recent conversation in the workspace". ACP names the session.
      #
      # On the sandbox that minted the id: a `ready` row routes the server
      # through reattach, which is what a second turn after a server restart
      # looks like. (This test used to start from a `pending` sandbox with a
      # prior id — a fresh provision — which is the #778 shape and now,
      # correctly, does not resume; see the describe below.)
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      conv =
        insert_conversation(
          agent: acp_agent(user),
          user_id: user.id,
          sandbox: sandbox,
          status: "idle",
          runtime_session_id: "sess_prior"
        )

      {pid, ref} = start_acp_turn(conv)

      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      decoded = next_write()
      assert decoded["method"] == "session/resume"
      assert decoded["params"]["sessionId"] == "sess_prior"
    end
  end

  describe "a wake onto a fresh sandbox (#778)" do
    test "starts a new runtime session instead of resuming one the disk never saw" do
      # The conversation's previous sandbox is gone (ceiling destroy, failed
      # probe, …) and the wake took the :create_new arm: a `pending` row and
      # a fresh provision, but the row still names the session that lived on
      # the old disk. Resuming it fails `-32002 Resource not found` on every
      # prompt until the conversation is terminated. The server must forget
      # the id when it provisions fresh, so the next turn is `session/new`.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          agent: acp_agent(user),
          user_id: user.id,
          sandbox: sandbox,
          status: "idle",
          runtime_session_id: "sess_on_the_old_disk"
        )

      {pid, ref} = start_acp_turn(conv)

      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      decoded = next_write()
      assert decoded["method"] == "session/new"
      refute Map.has_key?(decoded["params"], "sessionId")

      # The stale id is gone from the row (the turn start persists a fresh
      # placeholder, which `session/new` overwrites below), and the transcript
      # says why the agent's memory did not follow.
      refute Conversations._unsafe_get_conversation!(conv.id).runtime_session_id ==
               "sess_on_the_old_disk"

      assert %{data: data} =
               conv.id
               |> Conversations._unsafe_list_log_events()
               |> Enum.find(&(&1.kind == "stage" and &1.stage == "session"))

      assert %{"event" => "reset", "reason" => "fresh_sandbox"} = Jason.decode!(data)

      # And the id the agent mints on the new disk is what the next turn
      # resumes by — the same round trip as a brand-new conversation.
      reply(pid, ref, decoded["id"], %{"sessionId" => "sess_new_disk"})

      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id ==
               "sess_new_disk"
    end

    test "a conversation that never had a session does not get a spurious reset event" do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)

      {pid, ref} = start_acp_turn(conv)
      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})
      %{"method" => "session/new"} = next_write()

      refute conv.id
             |> Conversations._unsafe_list_log_events()
             |> Enum.any?(&(&1.kind == "stage" and &1.stage == "session"))
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

  describe "reattach — a deploy lands mid-turn" do
    # Every deploy restarts every ConversationServer; the adapter in the sprite
    # is a detachable session and keeps running. Before this describe existed
    # the reattach path re-hooked the command and logged its stdout raw: no
    # peer, so nobody answered `session/request_permission` and nobody saw the
    # `session/prompt` response. Every ACP turn in flight across a deploy hung
    # until the user prompted again (interrupting it) or the sandbox hit its
    # lifetime ceiling — 8 such turns were found stuck in production the day
    # this was written, one of them 15 hours in.

    # A conversation with a `ready` sandbox and a `running` turn, which is
    # exactly what the server finds after a restart. `attach` hands back a
    # command with our ref; every stdin write reaches the test process.
    defp reattach_fixture(prompt_id) do
      user = insert_verified_user()
      agent = acp_agent(user)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      conv =
        insert_conversation(
          agent: agent,
          user_id: user.id,
          sandbox: sandbox,
          status: "running",
          runtime_session_id: "sess_live"
        )

      turn =
        insert_turn(conv, %{
          status: "running",
          prompt: "long task",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second),
          acp_prompt_id: prompt_id
        })

      stub_happy_sprite()
      test = self()
      ref = make_ref()

      Mimic.stub(Fountain.Sandbox.Sprites, :list_sessions, fn _h ->
        {:ok, [%Fountain.Sandbox.Session{id: "9350"}]}
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :attach, fn _h, "9350", _opts ->
        {:ok, %Fountain.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :write_stdin, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :close_stdin, fn _c ->
        send(test, :stdin_closed)
        :ok
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :stop_command, fn _c ->
        send(test, :command_stopped)
        :ok
      end)

      {conv, turn, ref}
    end

    defp start_reattached(conv) do
      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      pid
    end

    defp raw_update(update) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => "sess_live", "update" => update}
      }) <> "\n"
    end

    test "a peer joins the running turn: permission answered, prompt response ends it", %{} do
      {conv, turn, ref} = reattach_fixture(4)
      pid = start_reattached(conv)

      assert is_pid(:sys.get_state(pid).acp_peer)
      # Attach mode is silent on start: no initialize, no second prompt.
      refute_receive {:wrote, _}, 100

      # The sprite replays a mid-line tail, then live-tails. Here the agent
      # asks permission mid-tool-call — the exact frame found at the end of the
      # hung production turn.
      send(pid, {:stdout, %{ref: ref}, ~s(le":"tail-of-a-replayed-line"}}}\n)})

      send(
        pid,
        {:stdout, %{ref: ref},
         Jason.encode!(%{
           "jsonrpc" => "2.0",
           "id" => 5,
           "method" => "session/request_permission",
           "params" => %{"options" => [%{"optionId" => "allow", "kind" => "allow_once"}]}
         }) <> "\n"}
      )

      assert_receive {:wrote, answer}, 1_000

      assert %{"id" => 5, "result" => %{"outcome" => %{"optionId" => "allow"}}} =
               Jason.decode!(answer)

      reply(pid, ref, 4, %{"stopReason" => "end_turn"})

      assert_receive :stdin_closed, 1_000
      assert Fountain.Repo.reload!(turn).status == "completed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
      assert :sys.get_state(pid).current_command == nil
    end

    test "replayed lines already persisted are not written twice; new ones are", %{} do
      {conv, turn, ref} = reattach_fixture(4)

      already = raw_update(%{"sessionUpdate" => "usage_update", "used" => 100})

      # What the previous peer persisted for this turn: the peer's own
      # re-encoding of the line, which is what a fresh peer produces again.
      {:notification, "session/update", params} =
        Fountain.Runtimes.ACP.Protocol.classify_line(String.trim_trailing(already, "\n"))

      Conversations.log!(%{
        conversation_id: conv.id,
        turn_id: turn.id,
        kind: "output",
        stream: "acp",
        stage: "turn",
        data:
          IO.iodata_to_binary(
            Fountain.Runtimes.ACP.Protocol.notification("session/update", params)
          )
      })

      pid = start_reattached(conv)
      fresh = raw_update(%{"sessionUpdate" => "usage_update", "used" => 250})

      # The replay repeats the persisted line and brings one the old server
      # never saw (emitted during the deploy gap).
      send(pid, {:stdout, %{ref: ref}, already <> fresh})
      settle(pid)

      acp = Enum.filter(Conversations._unsafe_list_log_events(conv.id), &(&1.stream == "acp"))
      assert Enum.count(acp, &(&1.data =~ ~s("used":100))) == 1
      assert Enum.count(acp, &(&1.data =~ ~s("used":250))) == 1
    end

    test "a turn whose prompt was never sent is orphaned and its adapter stopped", %{} do
      # The previous peer died mid-handshake: the adapter is idle waiting for a
      # prompt no peer can now write. Nothing to resume — end it cleanly rather
      # than leave a session the next reattach would bind to.
      {conv, turn, _ref} = reattach_fixture(nil)
      pid = start_reattached(conv)

      assert_receive :command_stopped, 1_000
      assert :sys.get_state(pid).acp_peer == nil
      assert :sys.get_state(pid).current_command == nil
      assert Fountain.Repo.reload!(turn).status == "interrupted"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      stages = Enum.filter(Conversations._unsafe_list_log_events(conv.id), &(&1.kind == "stage"))
      assert Enum.any?(stages, &(&1.stage == "reattach" and &1.data =~ "acp_prompt_not_sent"))
    end
  end

  # Restored with #659, as the note that replaced them asked. Gemini is the
  # only runtime whose adapter advertises `loadSession` and *no* `resume`, so
  # it is the one that exercises the expensive resumption path end to end —
  # and the only one whose session store Fountain has to defend against.
  describe "gemini over ACP (#659)" do
    setup do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "gemini")
      conv = insert_conversation(user_id: user.id, agent: agent)
      {:ok, user: user, agent: agent, conv: conv}
    end

    test "a gemini turn spawns the native ACP binary in its own workspace", ctx do
      {_pid, _ref} = start_acp_turn(ctx.conv)

      assert_receive {:spawned, "gemini", ["--acp"], opts}
      # /home/sprite would reintroduce the EACCES noise this workspace exists
      # to avoid, and gemini walks up from cwd looking for a .git.
      assert opts[:dir] == "/tmp/gemini-workspace"
    end

    test "protocol bytes never reach the transcript", ctx do
      {pid, ref} = start_acp_turn(ctx.conv)
      init = next_write()
      assert init["method"] == "initialize"

      reply(pid, ref, init["id"], %{"agentCapabilities" => %{"loadSession" => true}})
      _new = next_write()

      events = Conversations._unsafe_list_log_events(ctx.conv.id)
      refute Enum.any?(events, &(&1.kind == "output" and &1.data =~ "jsonrpc"))
    end

    test "an agent advertising loadSession and no resume takes session/load", ctx do
      # Gemini's exact shape. `session/resume` would be cheaper and it is not
      # on offer, which is why Peer's replay-discard exists at all.
      {pid, ref} = start_acp_turn(ctx.conv, %{}, Fountain.Test.FakeRuntime)
      init = next_write()
      reply(pid, ref, init["id"], %{"agentCapabilities" => %{"loadSession" => true}})

      new = next_write()
      assert new["method"] == "session/new"
    end
  end

  describe "permission ask path (#940)" do
    defp ask_agent(user) do
      insert_agent(user_id: user.id, runtime: "claude", permission_policy: %{"Bash" => "ask"})
    end

    defp raise_permission(pid, ref, id) do
      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"title" => "Bash", "kind" => "execute"},
            "options" => [
              %{"optionId" => "yes", "kind" => "allow_always"},
              %{"optionId" => "no", "kind" => "reject_once"}
            ]
          }
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)

      # The id a client answers with is minted by the peer, not the adapter's
      # own — claude and codex both number theirs from 0 per turn (#957). Tests
      # read it back rather than assuming it.
      :sys.get_state(pid).current_turn.pending_permission["request_id"]
    end

    test "a held request is persisted on the turn and announced on the stream" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()

      request_id = raise_permission(pid, ref, 301)

      # Persisted first, so a deploy landing a millisecond later can still
      # answer it.
      turn = :sys.get_state(pid).current_turn
      assert turn.pending_permission["request_id"] == request_id
      assert request_id =~ ~r/^301\./
      assert turn.pending_permission["tool"] == "Bash"

      # And announced, with the agent's own options.
      events = Conversations._unsafe_list_log_events(conv.id)
      stage = Enum.find(events, &(&1.kind == "stage" and &1.stage == "request"))
      assert stage.state == "started"
      assert Jason.decode!(stage.data)["request_id"] == request_id
    end

    test "the request renders as a permission_request block in the transcript" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()

      request_id = raise_permission(pid, ref, 302)

      blocks =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.stream == "acp"))
        |> Enum.flat_map(&Fountain.Conversations.Blocks.for_event(&1, "claude"))

      assert block = Enum.find(blocks, &(&1.kind == :permission_request))
      assert block.request_id == request_id
      assert block.name == "Bash"
      assert Enum.map(block.options, & &1["optionId"]) == ["yes", "no"]
    end

    test "answering writes the selected option and resolves the card" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()
      request_id = raise_permission(pid, ref, 303)

      assert :ok = GenServer.call(pid, {:answer_permission, request_id, "yes"})

      assert %{"id" => 303, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()

      # The turn no longer holds it, and the stream says how it ended.
      assert :sys.get_state(pid).current_turn.pending_permission == nil

      done =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "request" and &1.state == "done"))

      assert [event] = done
      assert Jason.decode!(event.data)["outcome"] == "answered"
    end

    test "a resolution is state done, never failed, even for a refusal" do
      # publish_stage's stage and status are the Prometheus counter's only tags
      # and there is an alert on them. A deny emitting `failed` would page
      # someone for a policy doing exactly what it was told.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()
      request_id = raise_permission(pid, ref, 304)

      send(pid, {:permission_timeout, request_id})
      settle(pid)

      states =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "request"))
        |> Enum.map(& &1.state)

      assert "done" in states
      refute "failed" in states
    end

    test "a timeout denies, and the denial is audited" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()
      request_id = raise_permission(pid, ref, 305)

      send(pid, {:permission_timeout, request_id})
      settle(pid)

      # Deny is the only safe default, and it picks the agent's own rejection.
      assert %{"id" => 305, "result" => %{"outcome" => %{"optionId" => "no"}}} = next_write()

      assert Enum.any?(
               Fountain.Audit.list_recent_for_user(user.id, 20),
               &(&1.action == "conversation.permission_denied")
             )
    end

    test "answering an id that was never offered is refused, not forwarded" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()
      request_id = raise_permission(pid, ref, 306)

      assert {:error, :unknown_option} =
               GenServer.call(pid, {:answer_permission, request_id, "made-up"})

      assert :sys.get_state(pid).current_turn.pending_permission["request_id"] == request_id
    end

    test "a sprite may not answer its own prompt" do
      # It holds a FOUNTAIN_TOKEN and could otherwise approve the very tool it
      # just asked for, which would make the policy decorative.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()
      request_id = raise_permission(pid, ref, 307)

      assert {:error, :sprite_may_not_answer} =
               Conversations.answer_permission_request(conv.id, user.id, request_id, "yes",
                 actor: "sprite"
               )
    end

    test "another tenant cannot answer, and gets not_found rather than a hint" do
      user = insert_verified_user()
      other = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()
      request_id = raise_permission(pid, ref, 308)

      assert {:error, :not_found} =
               Conversations.answer_permission_request(conv.id, other.id, request_id, "yes")
    end

    test "a request still held when the turn ends is resolved, not left open" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: ask_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      _request_id = raise_permission(pid, ref, 309)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      done =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "request" and &1.state == "done"))

      assert [event] = done
      assert Jason.decode!(event.data)["outcome"] == "turn_ended"
    end
  end
end
