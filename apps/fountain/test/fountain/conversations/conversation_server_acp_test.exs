defmodule Fountain.Conversations.ConversationServerACPTest do
  @moduledoc """
  The ACP path through a real `ConversationServer` (0014 gate 2).

  These are the assertions that cannot be made against the peer alone: which
  binary gets spawned, that stdin is *not* closed at spawn, that protocol bytes
  never reach the transcript, and that a turn ends exactly once even though it
  now has two possible terminators.
  """

  use Fountain.ConversationServerCase

  alias Fountain.Conversations.Lifecycle
  alias Managoat.Runtimes.ACP

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
  defp start_acp_turn(conv, credentials \\ %{}, runtime \\ Managoat.Runtimes.Testing.FakeRuntime) do
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

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c ->
      send(test, :stdin_closed)
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
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
    reply(pid, ref, new_id, %{"sessionId" => "sess_1", "models" => %{}})
    %{"id" => set_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, set_id, %{})

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
      # Spawned through `env` so the session carries its conversation tag on
      # its own command line (ADR 0023 gate 1); the adapter is argv[1].
      assert_receive {:spawned, "env", ["FOUNTAIN_CONVERSATION_ID=" <> _, bin | _], opts}
      assert bin == ACP.adapter_bin("claude")
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

    test "a rejected model fails before inference and reaches API and stream state", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})
      %{"id" => new_id} = next_write()
      reply(pid, ref, new_id, %{"sessionId" => "sess_1", "models" => %{}})
      %{"id" => set_id, "method" => "session/set_model"} = next_write()

      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => set_id,
          "error" => %{"code" => -32_602, "message" => "Invalid params"}
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)
      refute_receive {:wrote, _}, 50
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert turn.acp_prompt_id == nil
      assert turn.model_selection["effective_model"] == nil
      assert turn.model_selection["error"] =~ "No prompt was sent"
      assert :sys.get_state(pid).acp_peer == nil
      %{data: [wire]} = FountainWeb.ConversationJSON.turns(%{turns: [turn]})
      assert wire.model_selection == turn.model_selection

      assert Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.stage == "model" and &1.state == "failed" and &1.data =~ "Invalid params")
             )
    end

    test "a reconnect checks the adapter pin and an update failure prevents spawning", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert_receive {:spawned, _, _, _}
      GenServer.stop(:sys.get_state(pid).acp_peer)
      settle(pid)

      test = self()

      Mimic.expect(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _, "claude", _ ->
        send(test, :adapter_checked)
        {:error, :registry_unavailable}
      end)

      assert :ok = GenServer.call(pid, {:send_prompt, "next", []})
      assert_receive :adapter_checked
      refute_receive {:spawned, _, _, _}, 50
      assert [first, second] = Conversations._unsafe_list_turns(conv.id)
      assert first.status == "completed"
      assert second.status == "failed"
      assert second.acp_prompt_id == nil
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == "sess_1"
    end

    test "a saved model change is applied on the existing connection", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      peer = :sys.get_state(pid).acp_peer
      agent = Fountain.Agents._unsafe_get_agent(conv.agent_id)
      {:ok, _} = Fountain.Agents.update_agent(agent, %{model: "anthropic/claude-opus-4-6"})
      assert :ok = GenServer.call(pid, {:send_prompt, "next", []})

      assert %{
               "method" => "session/set_model",
               "id" => set_id,
               "params" => %{"modelId" => "claude-opus-4-6", "sessionId" => "sess_1"}
             } = next_write()

      assert :sys.get_state(pid).acp_peer == peer
      reply(pid, ref, set_id, %{"models" => %{"currentModelId" => "claude-opus-4-6"}})
      %{"method" => "session/prompt", "id" => prompt_id} = next_write()
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert [first, second] = Conversations._unsafe_list_turns(conv.id)
      assert first.status == "completed"
      assert second.model_selection["effective_model"] == "claude-opus-4-6"
      assert second.model_selection["source"] == "runtime"
      assert Conversations._unsafe_get_conversation!(conv.id).runtime_session_id == "sess_1"
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

    test "the stop reason ends the turn but leaves the connection open (#817)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # The connection outlives the turn: stdin is NOT closed, the peer is
      # idle, and the command is still ours — a background task the agent
      # left running keeps running.
      refute_receive :stdin_closed, 100
      state = :sys.get_state(pid)
      assert is_pid(state.acp_peer)
      refute is_nil(state.current_command)
      assert is_nil(state.current_turn)
    end

    test "a second prompt reuses the connection — no handshake (#817)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})

      # The very next thing on the wire is session/prompt on the open session:
      # no initialize, no session/new, no session/resume.
      %{"method" => "session/set_model", "id" => set_id} = next_write()
      reply(pid, ref, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2
    end

    for active <- [false, true], malformed <- [false, true] do
      test "saved policy refusal preserves active=#{active}, malformed=#{malformed}", ctx do
        prompt_id = drive_to_prompt(ctx.pid, ctx.ref)
        reply(ctx.pid, ctx.ref, prompt_id, %{"stopReason" => "end_turn"})

        if unquote(active) do
          notify(ctx.pid, ctx.ref, %{
            "sessionUpdate" => "agent_message_chunk",
            "text" => "working"
          })

          assert :sys.get_state(ctx.pid).current_turn.origin == "autonomous"
        end

        allowance =
          ctx.conv.id
          |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{max_model_turns: 2})
          |> Fountain.Repo.insert!()

        if unquote(malformed) do
          allowance
          |> Ecto.Changeset.change(limits: %{"private-field" => "do not echo"})
          |> Fountain.Repo.update!()
        end

        before = :sys.get_state(ctx.pid)
        turns = Conversations._unsafe_list_turns(ctx.conv.id)
        conv = Fountain.Repo.reload!(ctx.conv)
        usage_count = Fountain.Repo.aggregate(Fountain.Billing.UsageEvent, :count)
        {_key, raw} = insert_api_key(Fountain.Accounts.get_user!(ctx.conv.user_id))

        expect(Horde.Registry, :lookup, fn Fountain.ConversationRegistry, id ->
          assert id == ctx.conv.id
          [{ctx.pid, nil}]
        end)

        response =
          Phoenix.ConnTest.build_conn()
          |> FountainWeb.ConnCase.authed_with_key(raw)
          |> FountainWeb.ConnCase.post_json("/api/conversations/#{ctx.conv.id}/prompts", %{
            prompt: "continue"
          })
          |> Phoenix.ConnTest.json_response(422)

        if unquote(malformed) do
          assert response == %{
                   "error" => "execution_limits_invalid",
                   "errors" => %{"execution_limits" => ["invalid unknown_field"]}
                 }
        else
          assert response["error"] == "execution_limits_unsupported"
          assert response["message"] =~ "max_model_turns"
        end

        assert FountainWeb.SchemaGuard.take(self()) == []
        assert :sys.get_state(ctx.pid) == before
        assert Conversations._unsafe_list_turns(ctx.conv.id) == turns
        assert Fountain.Repo.reload!(ctx.conv) == conv
        assert Fountain.Repo.aggregate(Fountain.Billing.UsageEvent, :count) == usage_count
        refute_received :stdin_closed
        refute_received {:wrote, _}

        if unquote(active) do
          assert :ok = GenServer.call(ctx.pid, :interrupt)
          assert is_nil(:sys.get_state(ctx.pid).current_turn)
          assert List.last(Conversations._unsafe_list_turns(ctx.conv.id)).status == "interrupted"
        end
      end
    end

    test "empty saved policy still supersedes autonomous work on the same connection", ctx do
      prompt_id = drive_to_prompt(ctx.pid, ctx.ref)
      reply(ctx.pid, ctx.ref, prompt_id, %{"stopReason" => "end_turn"})
      notify(ctx.pid, ctx.ref, %{"sessionUpdate" => "agent_message_chunk", "text" => "working"})
      peer = :sys.get_state(ctx.pid).acp_peer

      ctx.conv.id
      |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{})
      |> Fountain.Repo.insert!()

      assert :ok = GenServer.call(ctx.pid, {:send_prompt, "again", []})
      assert :sys.get_state(ctx.pid).acp_peer == peer

      assert [
               %{status: "completed"},
               %{origin: "autonomous", status: "completed"},
               %{origin: "user", status: "running"}
             ] = Conversations._unsafe_list_turns(ctx.conv.id)

      %{"method" => "session/set_model", "id" => set_id} = next_write()
      reply(ctx.pid, ctx.ref, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
    end

    test "a running user turn remains busy under a saved limit", ctx do
      drive_to_prompt(ctx.pid, ctx.ref)

      ctx.conv.id
      |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{max_model_turns: 2})
      |> Fountain.Repo.insert!()

      before = :sys.get_state(ctx.pid)
      assert {:error, :busy} = GenServer.call(ctx.pid, {:send_prompt, "again", []})
      assert :sys.get_state(ctx.pid) == before
    end

    for active <- [false, true], malformed <- [false, true] do
      test "queued policy refusal preserves active=#{active}, malformed=#{malformed}", ctx do
        prompt_id = drive_to_prompt(ctx.pid, ctx.ref)
        reply(ctx.pid, ctx.ref, prompt_id, %{"stopReason" => "end_turn"})

        if unquote(active) do
          notify(ctx.pid, ctx.ref, %{
            "sessionUpdate" => "agent_message_chunk",
            "text" => "working"
          })

          assert :sys.get_state(ctx.pid).current_turn.origin == "autonomous"
        end

        allowance =
          ctx.conv.id
          |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{max_model_turns: 2})
          |> Fountain.Repo.insert!()

        if unquote(malformed) do
          allowance
          |> Ecto.Changeset.change(limits: %{"private-field" => "do not echo"})
          |> Fountain.Repo.update!()
        end

        before = :sys.get_state(ctx.pid)
        turns = Conversations._unsafe_list_turns(ctx.conv.id)
        conv = Fountain.Repo.reload!(ctx.conv)
        usage_count = Fountain.Repo.aggregate(Fountain.Billing.UsageEvent, :count)

        ConversationServer.queue_initial_prompt(ctx.pid, "queued")

        # Same-sender mailbox ordering waits for the queued cast to finish.
        assert :sys.get_state(ctx.pid) == before
        assert Conversations._unsafe_list_turns(ctx.conv.id) == turns
        assert Fountain.Repo.reload!(ctx.conv) == conv
        assert Fountain.Repo.aggregate(Fountain.Billing.UsageEvent, :count) == usage_count
        refute_received :stdin_closed
        refute_received {:wrote, _}

        if unquote(active) do
          assert :ok = GenServer.call(ctx.pid, :interrupt)
          assert is_nil(:sys.get_state(ctx.pid).current_turn)
          assert List.last(Conversations._unsafe_list_turns(ctx.conv.id)).status == "interrupted"
        end
      end
    end

    test "an empty saved allowance permits queued handoff on the same connection", ctx do
      prompt_id = drive_to_prompt(ctx.pid, ctx.ref)
      reply(ctx.pid, ctx.ref, prompt_id, %{"stopReason" => "end_turn"})
      notify(ctx.pid, ctx.ref, %{"sessionUpdate" => "agent_message_chunk", "text" => "working"})
      peer = :sys.get_state(ctx.pid).acp_peer

      ctx.conv.id
      |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{})
      |> Fountain.Repo.insert!()

      ConversationServer.queue_initial_prompt(ctx.pid, "queued")
      assert :sys.get_state(ctx.pid).acp_peer == peer

      assert [
               %{status: "completed"},
               %{origin: "autonomous", status: "completed"},
               %{origin: "user", status: "running", prompt: "queued"}
             ] = Conversations._unsafe_list_turns(ctx.conv.id)

      %{"method" => "session/set_model", "id" => set_id} = next_write()
      reply(ctx.pid, ctx.ref, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
    end

    test "a queued prompt leaves a running user turn alone under saved limits", ctx do
      drive_to_prompt(ctx.pid, ctx.ref)

      ctx.conv.id
      |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{max_model_turns: 2})
      |> Fountain.Repo.insert!()

      before = :sys.get_state(ctx.pid)
      ConversationServer.queue_initial_prompt(ctx.pid, "queued")
      assert :sys.get_state(ctx.pid) == before
    end

    test "an out-of-turn update opens an autonomous turn; cycle_end closes it (#817)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert is_nil(:sys.get_state(pid).current_turn)

      # The agent's background task comes back and narrates, out of turn.
      notify(pid, ref, %{"sessionUpdate" => "agent_message_chunk", "text" => "CI passed"})

      autonomous = :sys.get_state(pid).current_turn
      assert autonomous.origin == "autonomous"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "running"

      # A usage_update carrying an autonomous origin ends the cycle.
      notify(pid, ref, %{
        "sessionUpdate" => "usage_update",
        "_meta" => %{"_claude/origin" => %{"kind" => "task-notification"}}
      })

      assert is_nil(:sys.get_state(pid).current_turn)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      turns = Conversations._unsafe_list_turns(conv.id)
      assert Enum.any?(turns, &(&1.origin == "autonomous" and &1.status == "completed"))
    end

    for change <- [:retire, :move], input <- [:prompt, :background, :permission] do
      test "a stale actor cannot start #{input} work after #{change}", ctx do
        prompt_id = drive_to_prompt(ctx.pid, ctx.ref)
        reply(ctx.pid, ctx.ref, prompt_id, %{"stopReason" => "end_turn"})
        conv = Conversations._unsafe_get_conversation!(ctx.conv.id)

        case unquote(change) do
          :retire ->
            sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "terminated"})

          :move ->
            fresh = insert_sandbox(user_id: conv.user_id, status: "ready")
            {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: fresh.id})
        end

        case unquote(input) do
          :prompt ->
            assert :ok = GenServer.call(ctx.pid, {:send_prompt, "late prompt", []})

          :permission ->
            send(ctx.pid, {:acp, ctx.ref, {:permission_ask, "late-request", "Bash", []}})

          :background ->
            notify(ctx.pid, ctx.ref, %{
              "sessionUpdate" => "agent_message_chunk",
              "text" => "late output"
            })
        end

        state = :sys.get_state(ctx.pid)
        assert is_nil(state.current_turn)
        assert is_nil(state.acp_peer)
        assert is_nil(state.permission_timer)
        assert state.caller_calls == %{}
        assert [%{status: "completed"}] = Conversations._unsafe_list_turns(conv.id)
        assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

        refute Enum.any?(
                 Conversations._unsafe_list_log_events(conv.id),
                 &String.contains?(&1.data || "", "late output")
               )
      end
    end

    test "an out-of-turn session_info_update opens no autonomous turn (#1300)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert is_nil(:sys.get_state(pid).current_turn)

      # The claude adapter writes the generated session title about a second
      # after every prompt response — session metadata, not the agent talking.
      notify(pid, ref, %{
        "sessionUpdate" => "session_info_update",
        "title" => "Research Xfinity internet promotion pricing",
        "updatedAt" => "2026-08-25T12:05:48.620Z"
      })

      assert is_nil(:sys.get_state(pid).current_turn)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
      assert [%{origin: "user"}] = Conversations._unsafe_list_turns(conv.id)

      # With no turn to attach it to, the line is dropped, not persisted.
      refute Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.data =~ "session_info_update")
             )
    end

    test "session metadata mid-turn still lands on the transcript (#1300)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      notify(pid, ref, %{"sessionUpdate" => "session_info_update", "title" => "Early title"})

      assert Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.stream == "acp" and &1.data =~ "session_info_update")
             )

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert [%{origin: "user", status: "completed"}] = Conversations._unsafe_list_turns(conv.id)
    end

    test "metadata does not re-arm the quiet timer holding an autonomous turn open (#1300)", %{
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      # A real background narration opens the turn and arms the quiet timer.
      notify(pid, ref, %{"sessionUpdate" => "agent_message_chunk", "text" => "CI passed"})
      %{current_turn: %{origin: "autonomous"}, autonomous_quiet: timer} = :sys.get_state(pid)
      assert is_reference(timer)

      # A title update mid-cycle persists into the open turn but must not
      # extend its life: the same timer is still the one running.
      notify(pid, ref, %{"sessionUpdate" => "session_info_update", "title" => "t"})
      assert :sys.get_state(pid).autonomous_quiet == timer

      # A further narration line does re-arm.
      notify(pid, ref, %{"sessionUpdate" => "agent_message_chunk", "text" => "and deployed"})
      refute :sys.get_state(pid).autonomous_quiet == timer
    end

    test "terminating the conversation closes the connection (#817)", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert is_pid(:sys.get_state(pid).acp_peer)

      assert :ok = GenServer.call(pid, :terminate_conv)

      # The adapter is EOF'd so it exits rather than lingering on the machine.
      assert_receive :stdin_closed, 1_000
      assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
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

    for reason <- ["max_tokens", "max_turn_requests", "unknown_future_reason"] do
      test "#{reason} fails the turn and retains its reported usage", %{
        conv: conv,
        pid: pid,
        ref: ref
      } do
        prompt_id = drive_to_prompt(pid, ref)

        reply(pid, ref, prompt_id, %{
          "stopReason" => unquote(reason),
          "usage" => %{"inputTokens" => 100, "outputTokens" => 25, "totalTokens" => 125}
        })

        assert [turn] = Conversations._unsafe_list_turns(conv.id)
        assert turn.status == "failed"
        assert turn.usage == %{"input" => 100, "output" => 25}
        assert turn.ended_at

        # A subsequent adapter exit cannot convert the incomplete turn to success
        # or count its partial work twice.
        send(pid, {:exit, %{ref: ref}, 0})
        _ = :sys.get_state(pid)
        assert [persisted] = Conversations._unsafe_list_turns(conv.id)
        assert persisted.status == "failed"
        conv = Conversations._unsafe_get_conversation!(conv.id)
        assert conv.usage_input_tokens == 100
        assert conv.usage_output_tokens == 25
      end
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
          Managoat.Runtimes.Claude
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
          Managoat.Runtimes.Claude
        )

      prompt_id = drive_to_prompt(pid, ref)
      oauth_error_reply(pid, ref, prompt_id)

      registered = Fountain.Conversations.Redaction.lookup(conv.id)
      assert "api-key-long-enough" in registered
      assert "oauth-token-long-enough" in registered
    end

    test "says so plainly when there is no api key to fall back to", %{conv: conv} do
      {pid, ref} =
        start_acp_turn(conv, %{claude_code_oauth_token: "oauth-token"}, Managoat.Runtimes.Claude)

      prompt_id = drive_to_prompt(pid, ref)
      oauth_error_reply(pid, ref, prompt_id)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"

      stage = failed_turn_stage(conv.id)
      assert stage.data =~ "no Anthropic API key is on file"
    end
  end

  describe "a model the provider refuses (#970)" do
    setup do
      user = insert_verified_user()

      agent =
        insert_agent(user_id: user.id, runtime: "gemini", model: "google/gemini-2.5-pro")

      {:ok, conv: insert_conversation(agent: agent, user_id: user.id)}
    end

    defp model_gone_reply(pid, ref, id) do
      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => 500,
            "message" =>
              "This model models/gemini-2.5-pro is no longer available to new users. " <>
                "Please update your code to use models/gemini-3.1-pro-preview for the " <>
                "latest features and improvements."
          }
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)
    end

    test "the turn fails with the provider's sentence, not an inspected tuple", %{conv: conv} do
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)
      model_gone_reply(pid, ref, prompt_id)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"

      stage = failed_turn_stage(conv.id)
      # The point of #970: what the tenant reads names the model, quotes the
      # provider (which names the replacement) and says what to change.
      assert stage.data =~ "gemini-2.5-pro"
      assert stage.data =~ "no longer available to new users"
      assert stage.data =~ "gemini-3.1-pro-preview"
      assert stage.data =~ "Change the agent's model"
      refute stage.data =~ ":acp_error"
    end

    test "publishes a model stage carrying the requested id as a field", %{conv: conv} do
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)
      model_gone_reply(pid, ref, prompt_id)

      assert stage =
               conv.id
               |> Conversations._unsafe_list_log_events()
               |> Enum.find(
                 &(&1.kind == "stage" and &1.stage == "model" and &1.state == "failed")
               )

      assert stage.state == "failed"
      assert stage.data =~ "gemini-2.5-pro"
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

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _c, _a, _o ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      # Nothing should be written into the sandbox filesystem for an ACP turn.
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, _contents, _opts ->
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

      Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _h ->
        {:ok,
         [
           %Managoat.Sandbox.Session{
             id: "9350",
             command: "env FOUNTAIN_CONVERSATION_ID=#{conv.id} claude-agent-acp"
           }
         ]}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _h, "9350", _opts ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c ->
        send(test, :stdin_closed)
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c ->
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

      settle(pid)
      # The turn ends; the reattached connection stays open for the next one
      # (#817), so stdin is not closed and the command is still ours.
      refute_receive :stdin_closed, 100
      assert Fountain.Repo.reload!(turn).status == "completed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
      refute :sys.get_state(pid).current_command == nil
      assert is_pid(:sys.get_state(pid).acp_peer)
    end

    test "replayed lines already persisted are not written twice; new ones are", %{} do
      {conv, turn, ref} = reattach_fixture(4)

      already = raw_update(%{"sessionUpdate" => "usage_update", "used" => 100})

      # What the previous peer persisted for this turn: the peer's own
      # re-encoding of the line, which is what a fresh peer produces again.
      {:notification, "session/update", params} =
        Managoat.ACP.Protocol.classify_line(String.trim_trailing(already, "\n"))

      Conversations.log!(%{
        conversation_id: conv.id,
        turn_id: turn.id,
        kind: "output",
        stream: "acp",
        stage: "turn",
        data: IO.iodata_to_binary(Managoat.ACP.Protocol.notification("session/update", params))
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

      assert_receive {:spawned, "env", ["FOUNTAIN_CONVERSATION_ID=" <> _, "gemini", "--acp"],
                      opts}

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
      {pid, ref} = start_acp_turn(ctx.conv, %{}, Managoat.Runtimes.Testing.FakeRuntime)
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

  describe "requests that outlive a turn (#1635)" do
    defp waiting_agent(user, policy \\ %{"Bash" => "ask"}) do
      insert_agent(user_id: user.id, runtime: "claude", permission_policy: policy)
    end

    # Same frame as `raise_permission/3`, plus whatever the agent puts in the
    # request's own `_meta`.
    defp raise_permission_with(pid, ref, id, meta) do
      params =
        %{
          "toolCall" => %{"title" => "Bash", "kind" => "execute"},
          "options" => [
            %{"optionId" => "yes", "kind" => "allow_once"},
            %{"optionId" => "no", "kind" => "reject_once"}
          ]
        }
        |> then(&if meta == %{}, do: &1, else: Map.put(&1, "_meta", meta))

      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "session/request_permission",
          "params" => params
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)

      :sys.get_state(pid).current_turn.pending_permission["request_id"]
    end

    # The harness starts servers outside Horde, so `ConversationServer.whereis/1`
    # cannot see them. A detached answer goes through `send_prompt/4`, which
    # asks the registry first, so the resume turn has to be able to find this
    # server rather than waking a second one.
    defp register(pid, conv_id) do
      Mimic.stub(Horde.Registry, :lookup, fn
        Fountain.ConversationRegistry, ^conv_id -> [{pid, nil}]
        _registry, _key -> []
      end)
    end

    # The detach closes the connection, so a resume turn re-handshakes:
    # `initialize`, `session/resume` (the caps advertise it), the model pin,
    # then the prompt. Returns the prompt's params.
    #
    # `models` on the session response is not decoration: a runtime that
    # exposes no model selection fails the turn, so a resume turn has to be
    # answered the way `drive_to_prompt/2` answers `session/new`.
    defp drive_to_resume_prompt(pid, ref) do
      %{"id" => init_id, "method" => "initialize"} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      %{"id" => session_id, "method" => "session/resume"} = next_write()
      reply(pid, ref, session_id, %{"models" => %{}})

      %{"id" => set_id, "method" => "session/set_model"} = next_write()
      reply(pid, ref, set_id, %{})

      %{"method" => "session/prompt", "params" => params} = next_write()
      settle(pid)
      params
    end

    defp stages(conv_id, stage, state) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.filter(&(&1.kind == "stage" and &1.stage == stage and &1.state == state))
      |> Enum.map(&Jason.decode!(&1.data))
    end

    defp waiting_turn(conv_id) do
      Fountain.Repo.one!(
        from(t in Fountain.Conversations.Turn,
          where: t.conversation_id == ^conv_id and t.waiting == true
        )
      )
    end

    test "the agent ends the turn waiting and the request stays pending" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 401, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      # The turn is over, and it is a completed turn, not a failed one.
      state = :sys.get_state(pid)
      assert state.current_turn == nil

      turn = waiting_turn(conv.id)
      assert turn.status == "completed"
      assert turn.waiting
      assert turn.pending_permission["request_id"] == request_id
      assert turn.permission_deadline

      # And nothing denied it on the way out.
      assert stages(conv.id, "request", "done") == []

      # The conversation is idle, which is what lets the sandbox park.
      assert Fountain.Repo.reload(conv).status == "idle"
    end

    test "the turn stage says the turn ended waiting, and on what" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 402, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      assert [done] = stages(conv.id, "turn", "done")
      assert done["waiting"] == true
      assert done["stop_reason"] == "waiting"
      assert done["waiting_deadline"]

      # Prefixed, so a client pairing permission cards on `request_id` does not
      # pair one to this event.
      assert done["waiting_request_id"] == request_id
      refute Map.has_key?(done, "request_id")
    end

    test "waiting with nothing held is an ordinary completed turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      turn = Fountain.Repo.one!(from(t in Fountain.Conversations.Turn))
      assert turn.status == "completed"
      refute turn.waiting
      refute turn.permission_deadline

      assert [done] = stages(conv.id, "turn", "done")
      refute Map.has_key?(done, "waiting")
    end

    test "a request still held when the turn ends normally is still denied" do
      # The `waiting` stop reason is the only thing that changes this, and a
      # turn that simply ends must not start leaving cards open.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      _request_id = raise_permission_with(pid, ref, 403, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert [done] = stages(conv.id, "request", "done")
      assert done["outcome"] == "turn_ended"

      assert Fountain.Repo.all(from(t in Fountain.Conversations.Turn, where: t.waiting == true)) ==
               []
    end

    test "the request's own _meta timeout is honoured, past the idle bound" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      two_days = 2 * 24 * 3600

      _request_id =
        raise_permission_with(pid, ref, 404, %{"fountain" => %{"timeout" => two_days}})

      # Announced at ask time, so a card knows what it gets if the turn ends.
      assert [started] = stages(conv.id, "request", "started")
      assert started["detached_timeout_ms"] == two_days * 1000
      assert started["timeout_ms"] == Lifecycle.ask_timeout_ms()

      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      deadline = waiting_turn(conv.id).permission_deadline
      idle_seconds = Lifecycle.idle_timeout_seconds()

      assert DateTime.diff(deadline, DateTime.utc_now()) > idle_seconds
    end

    test "the policy ask_timeout is used when the request names none" do
      user = insert_verified_user()
      agent = waiting_agent(user, %{"Bash" => "ask", "ask_timeout" => 4 * 3600})
      conv = insert_conversation(user_id: user.id, agent: agent)
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      _request_id = raise_permission_with(pid, ref, 405, %{})
      assert [started] = stages(conv.id, "request", "started")
      assert started["detached_timeout_ms"] == 4 * 3600 * 1000

      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      deadline = waiting_turn(conv.id).permission_deadline
      assert_in_delta DateTime.diff(deadline, DateTime.utc_now()), 4 * 3600, 30
    end

    test "with neither, a detached request keeps the global ceiling" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      _request_id = raise_permission_with(pid, ref, 406, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      deadline = waiting_turn(conv.id).permission_deadline
      expected = div(Lifecycle.ask_timeout_ms(), 1000)
      assert_in_delta DateTime.diff(deadline, DateTime.utc_now()), expected, 30
    end

    test "the turn's end closes the connection, so the resume turn gets a fresh peer" do
      # The peer holds the request it raised in a single slot that only an
      # answer or a denial clears, and the detached path sends neither. Keeping
      # the connection would carry that hold into the resume turn.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      _request_id = raise_permission_with(pid, ref, 407, %{})
      assert :sys.get_state(pid).acp_peer

      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      state = :sys.get_state(pid)
      assert state.acp_peer == nil
      assert state.current_command == nil
    end

    test "a permission timeout still in flight when the turn detaches is ignored" do
      # `Process.cancel_timer/1` does not recall a message already in the
      # mailbox, so the in-turn timer can fire between the ask and the
      # `waiting` frame. Resolving it here would deny a request that is still
      # open: every attached card would settle, and a
      # `conversation.permission_denied` row would record what did not happen.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 499, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      turn = waiting_turn(conv.id)

      send(pid, {:permission_timeout, request_id})
      settle(pid)

      after_turn = Fountain.Repo.reload(turn)
      assert after_turn.waiting
      assert after_turn.pending_permission["request_id"] == request_id
      assert after_turn.permission_deadline == turn.permission_deadline
      assert stages(conv.id, "request", "done") == []
    end

    test "answering opens a new turn whose prompt carries the request and the option" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 408, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})
      register(pid, conv.id)

      assert :ok =
               Conversations.answer_permission_request(conv.id, user.id, request_id, "yes",
                 actor: "api"
               )

      settle(pid)

      # A fresh connection: the old one went with the detach, so the resume
      # turn handshakes and resumes the session on the same disk.
      params = drive_to_resume_prompt(pid, ref)
      assert [%{"type" => "text", "text" => text}] = params["prompt"]

      assert %{"fountain/permission_answer" => answer} = Jason.decode!(text)
      assert answer["request_id"] == request_id
      assert answer["option_id"] == "yes"
      assert answer["outcome"] == "answered"
      assert answer["tool"] == "Bash"
    end

    test "a colliding request id in the resume turn is reported, carded and timed" do
      # claude-agent-acp and codex number their requests from 0 per turn, so
      # the resume turn's first request arrives under the id the detached one
      # used. Against a kept peer it matched the stale hold and vanished.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      first_id = raise_permission_with(pid, ref, 0, %{})
      assert first_id =~ ~r/^0\./
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})
      register(pid, conv.id)

      assert :ok = Conversations.answer_permission_request(conv.id, user.id, first_id, "yes")
      settle(pid)
      _params = drive_to_resume_prompt(pid, ref)

      # The same JSON-RPC id the detached request used.
      second_id = raise_permission_with(pid, ref, 0, %{})

      assert second_id =~ ~r/^0\./
      refute second_id == first_id

      turn = :sys.get_state(pid).current_turn
      assert turn.pending_permission["request_id"] == second_id
      assert turn.pending_permission["tool"] == "Bash"

      started =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "request" and &1.state == "started"))
        |> Enum.map(&Jason.decode!(&1.data))

      assert Enum.map(started, & &1["request_id"]) == [first_id, second_id]

      # And it is timed, so nobody answering still ends it.
      assert :sys.get_state(pid).permission_timer
      send(pid, {:permission_timeout, second_id})
      settle(pid)

      assert %{"id" => 0, "result" => %{"outcome" => %{"optionId" => "no"}}} = next_write()
    end

    test "a restart between the detach and the answer changes nothing: the row drives it" do
      # Nothing about a detached request lives in a process. The server that
      # raised it is gone by the time it is answered in the normal case
      # (the sandbox parked), so a deploy in the middle has to be the same
      # thing happening sooner.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 413, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      # The BEAM this was raised on goes away.
      GenServer.stop(pid)

      # Ownership: the tenant-scoped answer door below establishes it; this is
      # the assertion that the row alone still describes the request.
      assert [%{request_id: ^request_id, tool: "Bash"}] =
               Conversations._unsafe_list_pending_requests(conv.id)

      # No server, so the answer takes the wake path.
      test = self()

      Mimic.stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      Mimic.stub(ConversationServer, :queue_initial_prompt, fn _pid, prompt ->
        send(test, {:resume_prompt, prompt})
        :ok
      end)

      assert :ok = Conversations.answer_permission_request(conv.id, user.id, request_id, "yes")

      assert_receive {:resume_prompt, prompt}

      assert %{
               "fountain/permission_answer" => %{
                 "request_id" => ^request_id,
                 "option_id" => "yes"
               }
             } =
               Jason.decode!(prompt)
    end

    test "answering is refused for the sandbox's own token" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 412, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})

      assert {:error, :sprite_may_not_answer} =
               Conversations.answer_permission_request(conv.id, user.id, request_id, "yes",
                 actor: "sprite"
               )

      assert waiting_turn(conv.id).pending_permission["request_id"] == request_id
    end

    test "the resolution is audited with the answerer, not the sandbox" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 409, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})
      register(pid, conv.id)

      assert :ok =
               Conversations.answer_permission_request(conv.id, user.id, request_id, "yes",
                 actor: "ui",
                 request_ip: "198.51.100.7"
               )

      assert answered =
               user.id
               |> Fountain.Audit.list_recent_for_user(50)
               |> Enum.find(&(&1.action == "conversation.permission_answered"))

      assert answered.actor == "ui"
      assert answered.request_ip == "198.51.100.7"
      assert answered.metadata["request_id"] == request_id
    end

    test "the expiry opens the same resume turn, with the denial" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 410, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})
      register(pid, conv.id)

      # Age the deadline past, as a sweep an hour later would find it.
      turn = waiting_turn(conv.id)

      {:ok, _} =
        Fountain.Repo.update(
          Ecto.Changeset.change(turn,
            permission_deadline:
              DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
          )
        )

      assert Fountain.Workers.DetachedRequestSweeper.sweep_expired_requests() == 1
      settle(pid)

      params = drive_to_resume_prompt(pid, ref)
      assert [%{"text" => text}] = params["prompt"]

      assert %{"fountain/permission_answer" => answer} = Jason.decode!(text)
      assert answer["request_id"] == request_id
      assert answer["outcome"] == "timeout"
      # The agent's own rejection, never an invented id.
      assert answer["option_id"] == "no"
    end

    test "the request webhooks fire on the ask and on the resolution" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: waiting_agent(user))

      {:ok, {endpoint, _secret}} =
        Fountain.Webhooks.create_endpoint(user.id, %{
          "url" => "https://hooks.example.com/f",
          "event_types" => ["conversation.request.started", "conversation.request.done"]
        })

      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      request_id = raise_permission_with(pid, ref, 411, %{})
      reply(pid, ref, prompt_id, %{"stopReason" => "waiting"})
      register(pid, conv.id)

      assert [started] = webhook_types(endpoint)
      assert started == "conversation.request.started"

      assert :ok = Conversations.answer_permission_request(conv.id, user.id, request_id, "yes")

      assert webhook_types(endpoint) == [
               "conversation.request.started",
               "conversation.request.done"
             ]
    end

    defp webhook_types(endpoint) do
      Fountain.Repo.all(
        from(j in Oban.Job,
          where: fragment("?->>'endpoint_id' = ?", j.args, ^endpoint.id),
          order_by: j.id,
          select: fragment("?->'payload'->>'type'", j.args)
        )
      )
    end
  end

  describe "the tool bridge (#1202)" do
    @caller_tools [
      %{
        "name" => "lookup_order",
        "description" => "Find an order",
        "parameters" => %{"type" => "object"}
      }
    ]

    defp bridged_conv(user) do
      insert_conversation(user_id: user.id, agent: acp_agent(user), caller_tools: @caller_tools)
    end

    # `resolve_caller_tool/4` answers the waiter first and writes the stage row
    # second, so a result message in hand does not mean the row has landed —
    # the timeout and turn-ended paths resolve from a handler nobody waits on.
    # One call through the server's mailbox is the barrier: it is served only
    # after the handler that sent that message has returned.
    defp caller_stages(pid, conv_id, state) do
      _ = :sys.get_state(pid)

      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.filter(&(&1.kind == "stage" and &1.stage == "caller_tool" and &1.state == state))
      |> Enum.map(&Jason.decode!(&1.data))
    end

    test "the caller server rides in session/new only when tools are registered" do
      user = insert_verified_user()
      {pid, ref} = start_acp_turn(bridged_conv(user))
      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

      %{"method" => "session/new", "params" => params} = next_write()

      assert [%{"name" => "fountain-caller", "type" => "http", "url" => url}] =
               params["mcpServers"]

      assert String.contains?(url, "/api/mcp/caller/")

      plain = insert_conversation(user_id: user.id, agent: acp_agent(user))
      {pid2, ref2} = start_acp_turn(plain)
      %{"id" => init_id2} = next_write()
      reply(pid2, ref2, init_id2, %{"agentCapabilities" => @caps})
      %{"method" => "session/new", "params" => params2} = next_write()
      assert params2["mcpServers"] == []
    end

    test "a parked call is announced on the stream and resolved by the answer" do
      user = insert_verified_user()
      conv = bridged_conv(user)
      {pid, ref} = start_acp_turn(conv)
      _prompt_id = drive_to_prompt(pid, ref)

      assert {:ok, "call_" <> _ = id} =
               GenServer.call(pid, {:park_caller_tool, "lookup_order", %{"id" => "A-17"}, self()})

      assert [%{"call_id" => ^id, "name" => "lookup_order", "arguments" => %{"id" => "A-17"}}] =
               caller_stages(pid, conv.id, "started")

      assert [%{id: ^id, name: "lookup_order"}] = GenServer.call(pid, :pending_caller_calls)
      assert :pending = GenServer.call(pid, {:await_caller_tool, id, self()})

      assert {:ok, %{turn_id: turn_id, remaining: []}} =
               GenServer.call(pid, {:answer_caller_tools, %{id => "shipped", "stray" => "x"}})

      assert turn_id == :sys.get_state(pid).current_turn.id
      assert_receive {:caller_tool_result, ^id, {:ok, "shipped"}}

      assert [%{"call_id" => ^id, "outcome" => "answered"}] = caller_stages(pid, conv.id, "done")
      assert [] = GenServer.call(pid, :pending_caller_calls)

      # Kept for a waiter that asks after the fact.
      assert {:ok, {:ok, "shipped"}} = GenServer.call(pid, {:await_caller_tool, id, self()})

      assert {:error, :no_pending_calls} =
               GenServer.call(pid, {:answer_caller_tools, %{id => "again"}})

      assert {:error, :unknown_call} =
               GenServer.call(pid, {:await_caller_tool, "call_nope", self()})
    end

    test "the deadline resolves a call the caller never answered" do
      previous = Application.get_env(:fountain, :permission_ask_timeout_seconds)
      Application.put_env(:fountain, :permission_ask_timeout_seconds, 1)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fountain, :permission_ask_timeout_seconds, previous),
          else: Application.delete_env(:fountain, :permission_ask_timeout_seconds)
      end)

      user = insert_verified_user()
      conv = bridged_conv(user)
      {pid, ref} = start_acp_turn(conv)
      _prompt_id = drive_to_prompt(pid, ref)

      {:ok, id} = GenServer.call(pid, {:park_caller_tool, "lookup_order", %{}, self()})
      assert_receive {:caller_tool_result, ^id, {:error, reason}}, 3_000
      assert reason =~ "did not answer"
      assert [%{"call_id" => ^id, "outcome" => "timeout"}] = caller_stages(pid, conv.id, "done")

      # The turn is still running: the agent carries on.
      assert :sys.get_state(pid).current_turn.status == "running"
    end

    test "a call still parked when the turn ends is resolved, then dropped" do
      user = insert_verified_user()
      conv = bridged_conv(user)
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)

      {:ok, id} = GenServer.call(pid, {:park_caller_tool, "lookup_order", %{}, self()})
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert_receive {:caller_tool_result, ^id, {:error, _}}

      assert [%{"call_id" => ^id, "outcome" => "turn_ended"}] =
               caller_stages(pid, conv.id, "done")

      assert :sys.get_state(pid).caller_calls == %{}
    end

    test "parking needs a turn" do
      user = insert_verified_user()
      conv = bridged_conv(user)
      {pid, ref} = start_acp_turn(conv)
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert {:error, :no_turn} =
               GenServer.call(pid, {:park_caller_tool, "lookup_order", %{}, self()})
    end
  end

  describe "labels over the ACP extension (#1637)" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      {:ok, user: user, conv: conv, pid: pid, ref: ref}
    end

    defp labels_of(conv_id), do: Conversations._unsafe_get_conversation!(conv_id).labels

    test "the agent stamps its own conversation mid-turn", %{conv: conv, pid: pid, ref: ref} do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "_fountain/labels",
        "labels" => %{"drift" => "true", "env" => "prod"}
      })

      assert labels_of(conv.id) == %{"drift" => "true", "env" => "prod"}
    end

    test "a second stamp merges rather than replaces", %{conv: conv, pid: pid, ref: ref} do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"env" => "prod"}})
      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"run" => "17"}})

      assert labels_of(conv.id) == %{"env" => "prod", "run" => "17"}
    end

    test "a null value removes a key", %{conv: conv, pid: pid, ref: ref} do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "_fountain/labels",
        "labels" => %{"env" => "prod", "run" => "17"}
      })

      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"env" => nil}})

      assert labels_of(conv.id) == %{"run" => "17"}
    end

    test "the stamp never reaches the transcript", %{conv: conv, pid: pid, ref: ref} do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"env" => "prod"}})

      events = Conversations._unsafe_list_log_events(conv.id)
      refute Enum.any?(events, &(&1.data =~ "_fountain/labels"))
    end

    test "a stamp the limits refuse is dropped and the turn survives", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "_fountain/labels",
        "labels" => %{"note" => String.duplicate("v", 300)}
      })

      assert labels_of(conv.id) == %{}
      assert Process.alive?(pid)

      # And the turn still ends normally.
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end

    # Postgres refuses a NUL inside a jsonb string. Before `check_entry/2`
    # rejected it, the write raised a Postgrex.Error inside the turn machine,
    # which travelled up through `drive_turn/2` and killed the server and the
    # turn it was running — a label costing a run.
    test "a NUL byte in a stamp costs the stamp and not the turn", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "_fountain/labels",
        "labels" => %{"note" => "before\u0000after"}
      })

      assert labels_of(conv.id) == %{}
      assert Process.alive?(pid)

      # The turn still ends, and a later legal stamp still lands.
      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"env" => "prod"}})
      assert labels_of(conv.id) == %{"env" => "prod"}

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end

    # The extension is recognised by a decode, not by a substring: the cheap
    # `String.contains?` in front of it is an optimisation, and agent prose
    # that happens to mention the kind is still prose.
    test "agent output that mentions the kind is still transcript", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{
          "type" => "text",
          "text" => ~s|stamp it with {"sessionUpdate":"_fountain/labels"}|
        }
      })

      events = Conversations._unsafe_list_log_events(conv.id)
      assert Enum.any?(events, &(&1.stream == "acp" and &1.data =~ "_fountain/labels"))

      # And it labelled nothing.
      assert labels_of(conv.id) == %{}
    end

    test "a stamp out of turn opens no autonomous turn", %{conv: conv, pid: pid, ref: ref} do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      before = length(Conversations._unsafe_list_turns(conv.id))

      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"env" => "prod"}})

      assert labels_of(conv.id) == %{"env" => "prod"}
      assert length(Conversations._unsafe_list_turns(conv.id)) == before
    end

    test "the write is recorded as the sprite, with keys and no values", %{
      user: user,
      pid: pid,
      ref: ref
    } do
      drive_to_prompt(pid, ref)

      notify(pid, ref, %{"sessionUpdate" => "_fountain/labels", "labels" => %{"drift" => "true"}})

      assert [event] =
               user.id
               |> Fountain.Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))

      assert event.actor == "sprite"
      assert event.metadata["keys"] == ["drift"]
      refute inspect(event.metadata) =~ "true"
    end
  end
end
