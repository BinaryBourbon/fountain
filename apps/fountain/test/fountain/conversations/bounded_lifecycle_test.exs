defmodule Fountain.Conversations.BoundedLifecycleTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{
    ExecutionAllowance,
    ExecutionGuard,
    ExecutionLimits,
    Turn,
    TurnExecution
  }

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Command

  setup do
    # Only this offline test substitutes capabilities. Public admission remains
    # empty until the released provider and full live acceptance are available.
    stub(ExecutionLimits, :enforced_controls, fn _ -> ExecutionLimits.keys() end)
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, agent: agent, status: "idle")

    limits = %{"wall_time_seconds" => 60, "max_model_turns" => 2}
    save_allowance(conv.id, limits)

    %{conv: conv, sandbox: sandbox, user: user, limits: limits}
  end

  # The saved conversation allowance lives in `execution_allowances`, which
  # carries a revision so a launch and a resume cannot overwrite each other.
  defp save_allowance(conversation_id, limits) do
    Repo.delete_all(from a in ExecutionAllowance, where: a.conversation_id == ^conversation_id)
    conversation_id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert!()
  end

  defp attrs(c),
    do: %{
      conversation_id: c.conv.id,
      turn_number: 1,
      prompt: "review",
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

  defp admit(c) do
    {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs(c), c.sandbox.id, :unbounded)
    {turn, ExecutionGuard._unsafe_for_turn(turn.id)}
  end

  test "turn and immutable deadline are committed together; an open journal blocks another", c do
    {turn, execution} = admit(c)
    assert DateTime.compare(execution.deadline_at, DateTime.add(turn.started_at, 60)) == :eq
    assert execution.execution_limits == c.limits
    assert execution.user_id == c.user.id
    assert execution.spawn_submitted_at == nil

    assert {:error, :execution_fenced} =
             Conversations._unsafe_create_turn_on_sandbox(
               %{attrs(c) | turn_number: 2},
               c.sandbox.id,
               :unbounded
             )

    assert Repo.aggregate(Turn, :count) == 1
  end

  test "admission refuses unsupported controls without inserting a turn", c do
    stub(ExecutionLimits, :enforced_controls, fn _ -> [] end)

    assert {:error, {:execution_limits_unsupported, _}} =
             Conversations._unsafe_create_turn_on_sandbox(attrs(c), c.sandbox.id, :unbounded)

    assert Repo.aggregate(Turn, :count) == 0
    assert Repo.aggregate(TurnExecution, :count) == 0
  end

  test "a failed journal registration rolls back the new turn", c do
    c.sandbox |> Ecto.Changeset.change(status: "failed") |> Repo.update!()

    # `:sandbox_unavailable`, not the journal's `:sandbox_not_ready`: main's
    # admission proves the conversation is still attached to a non-terminal
    # sandbox owned by the same tenant (#1761, #1764) before the journal is
    # reached at all. Registration on top of that check is the point — it is
    # not a replacement for it.
    assert {:error, :sandbox_unavailable} =
             Conversations._unsafe_create_turn_on_sandbox(attrs(c), c.sandbox.id, :unbounded)

    assert Repo.aggregate(Turn, :count) == 0
    assert Repo.aggregate(TurnExecution, :count) == 0
  end

  test "SDK-only requests cannot acquire an invented wall allowance", c do
    save_allowance(c.conv.id, %{"max_model_turns" => 2})

    assert {:error, {:execution_limits_invalid, "wall_time_seconds_required"}} =
             Conversations._unsafe_create_turn_on_sandbox(attrs(c), c.sandbox.id, :unbounded)

    assert Repo.aggregate(Turn, :count) == 0
  end

  test "cancellation commits while the actor cannot reply and never calls the provider", c do
    {turn, execution} = admit(c)
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(
        execution.id,
        execution.connection_id,
        "cancel-session"
      )

    actor = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(actor, :kill) end)

    stub(ConversationServer, :whereis, fn id ->
      assert id == c.conv.id
      actor
    end)

    task = Task.async(fn -> ConversationServer.interrupt(c.conv.id) end)
    assert :ok = Task.await(task, 1_000)
    assert Repo.get!(Turn, turn.id).status == "interrupted"
    assert Repo.get!(TurnExecution, execution.id).state == "ready"
    assert Process.alive?(actor)
    assert :ok = ConversationServer.interrupt(c.conv.id)
  end

  test "deleting the parent retains cleanup when actor termination fails", c do
    {turn, execution} = admit(c)
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(
        execution.id,
        execution.connection_id,
        "delete-session"
      )

    stub(ConversationServer, :terminate_conversation, fn _, _ ->
      {:error, :provider_unavailable}
    end)

    assert {:ok, _} = Conversations.delete_conversation(c.conv)
    assert Repo.get(Turn, turn.id) == nil

    assert %{state: "ready", provider_session_id: "delete-session", sandbox_id: id} =
             Repo.get!(TurnExecution, execution.id)

    assert id == c.sandbox.id

    assert {:ok, %{execution: %{state: "ready"}}} =
             ExecutionGuard._unsafe_complete(execution.id, "interrupted")

    assert {:ok, %{permitted: true}} = ExecutionGuard._unsafe_claim_termination(execution.id)
  end

  test "deleted-parent cleanup cannot follow a changed sandbox identity", c do
    {_turn, execution} = admit(c)
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(
        execution.id,
        execution.connection_id,
        "original-session"
      )

    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    Repo.delete!(c.conv)
    c.sandbox |> Ecto.Changeset.change(sprite_name: "replacement-sandbox") |> Repo.update!()

    assert {:ok, %{permitted: false, execution: %{state: "uncertain"}}} =
             ExecutionGuard._unsafe_claim_termination(execution.id)

    assert Repo.get!(TurnExecution, execution.id).attempt_id == nil
  end

  test "a restarted actor retires the old journal before any sandbox reattachment", c do
    {turn, execution} = admit(c)
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(execution.id, execution.connection_id, "old-session")

    {_pid, _mon, :stopped} = start_server(c.conv)
    assert Repo.get!(Turn, turn.id).status == "interrupted"
    assert Repo.get!(TurnExecution, execution.id).state == "ready"
    assert {:error, :execution_fenced} = Conversations._unsafe_execution_limits_gate(c.conv)
  end

  test "the real actor launches tracked setup, passes SDK limits, and retires a successful turn",
       c do
    {pid, transport, ref, execution} = start_bounded(c)
    prompt_id = drive_to_prompt(transport, ref)
    reply(transport, ref, prompt_id, %{"stopReason" => "end_turn"})
    state = wait_idle(pid)
    assert state.turn_execution == nil
    assert state.current_command_ref == nil
    assert state.acp_peer == nil
    assert Repo.get!(Turn, execution.turn_id).status == "completed"
    assert Repo.get!(TurnExecution, execution.id).state == "ready"
    assert {:error, :execution_fenced} = GenServer.call(pid, {:send_prompt, "again", []})

    assert {:error, :execution_fenced} =
             Fountain.Conversations.ExecutionTransport.write(transport, "late")

    # The original peer's late background report cannot manufacture another turn.
    send(pid, {:acp, ref, {:done, "end_turn", %{}}})
    :sys.get_state(pid)
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "a broker refresh cannot discard the newly admitted journal", c do
    stub(Fountain.Conversations.Egress, :refresh_before_turn, fn state -> {state, true} end)
    {pid, _transport, _ref, execution} = start_bounded(c)
    assert :sys.get_state(pid).turn_execution.id == execution.id
    assert Repo.get!(TurnExecution, execution.id).state == "active"
    assert :ok = GenServer.call(pid, :interrupt)
    assert Repo.get!(TurnExecution, execution.id).state == "ready"
  end

  test "Codex wall deadlines preserve its capability wrapper without Claude SDK limits", c do
    agent = insert_agent(user_id: c.user.id, runtime: "codex", model: "openai/gpt-6")

    conv =
      c.conv
      |> Ecto.Changeset.change(runtime: "codex", agent_id: agent.id)
      |> Repo.update!()

    save_allowance(conv.id, %{"wall_time_seconds" => 60})

    {pid, _transport, _ref, execution} = start_bounded(%{c | conv: conv})

    assert_receive {:spawn_argv,
                    ["-c", _, "acp-bootstrap", installer, "/usr/bin/setpriv" | final_args]}

    assert installer =~ "@agentclientprotocol/codex-acp@"
    assert Enum.take(final_args, 3) == ["--inh-caps=-all", "--ambient-caps=-all", "--"]
    assert "codex-acp" in final_args
    assert execution.execution_limits == %{"wall_time_seconds" => 60}
    assert :ok = GenServer.call(pid, :interrupt)
    assert Repo.get!(TurnExecution, execution.id).state == "ready"
  end

  test "an unsupported provider cannot retain an admitted turn", c do
    c.sandbox |> Ecto.Changeset.change(provider: "runner") |> Repo.update!()

    assert {:error, :provider_not_supported} =
             Conversations._unsafe_create_turn_on_sandbox(attrs(c), c.sandbox.id, :unbounded)

    assert Repo.aggregate(Turn, :count) == 0
  end

  test "an adapter exit zero before a prompt reply is incomplete", c do
    {pid, transport, ref, execution} = start_bounded(c)
    _ = drive_to_prompt(transport, ref)
    send(transport, {:exit, %{ref: ref}, 0})
    wait_idle(pid)
    assert Repo.get!(Turn, execution.turn_id).status == "failed"
    assert Repo.get!(TurnExecution, execution.id).state == "ready"
  end

  test "deadline retirement fences queued actor output and preserves its failed outcome", c do
    {pid, transport, ref, execution} = start_bounded(c)
    prompt_id = drive_to_prompt(transport, ref)
    {:ok, _} = ExecutionGuard._unsafe_expire(execution.id, now: execution.deadline_at)
    reply(transport, ref, prompt_id, %{"stopReason" => "end_turn"})
    # A callback already queued before transport fencing still checks the journal.
    send(pid, {:acp, ref, {:done, "end_turn", %{}}})
    wait_idle(pid)

    assert %{status: "failed", limit_reason: "wall_time_limit"} =
             Repo.get!(Turn, execution.turn_id)

    assert Repo.aggregate(Turn, :count) == 1
  end

  test "the independent transport deadline releases an actor waiting on its peer", c do
    save_allowance(c.conv.id, %{"wall_time_seconds" => 3})

    {pid, _transport, _ref, execution} = start_bounded(c)
    # Leave initialize unanswered: the actor has no model output to wake it.
    wait_idle(pid, 500)

    assert %{status: "failed", limit_reason: "wall_time_limit"} =
             Repo.get!(Turn, execution.turn_id)

    assert Repo.get!(TurnExecution, execution.id).state == "ready"
  end

  test "retirement does not consume the only lifecycle timer", c do
    test = self()

    stub(Fountain.Conversations.Lifecycle, :schedule_check, fn ->
      send(test, :lifecycle_scheduled)
    end)

    {pid, _transport, _ref, execution} = start_bounded(c)
    assert_receive :lifecycle_scheduled
    {:ok, _} = ExecutionGuard._unsafe_expire(execution.id, now: execution.deadline_at)
    send(pid, :lifecycle_check)
    wait_idle(pid)
    assert_receive :lifecycle_scheduled
  end

  test "an autonomous turn under an allowance is bounded, not refused", c do
    # The original of this test asserted that any allowance refused autonomous
    # work outright. That would turn one configured ceiling into "no schedules
    # and no background follow-ups for this account", which is a product
    # decision nothing had written down. Routing autonomous turns through the
    # same admission gives them a journal and a deadline instead, so the
    # coordinator can expire one exactly as it expires a prompted turn.
    {turn, span, tracer} =
      Fountain.Conversations.Connection.open_autonomous_turn(
        c.conv.id,
        c.user.id,
        c.sandbox.id
      )

    assert turn.origin == "autonomous"
    assert span
    assert tracer

    execution = ExecutionGuard._unsafe_for_turn(turn.id)
    assert execution, "an autonomous turn under an allowance must be journalled"
    assert execution.execution_limits == c.limits
    assert DateTime.compare(execution.deadline_at, DateTime.add(turn.started_at, 60)) == :eq

    # And the fence still holds against a second one.
    assert {:error, :execution_fenced} =
             Fountain.Conversations.Connection.open_autonomous_turn(
               c.conv.id,
               c.user.id,
               c.sandbox.id
             )

    assert Repo.aggregate(Turn, :count) == 1
  end

  defp start_bounded(c) do
    stub_happy_sprite(c.sandbox.sprite_name)
    stub(Sandbox.Sprites, :stop_command, fn _ -> :ok end)
    {pid, _mon, :alive} = start_server(c.conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    test = self()
    ref = make_ref()

    stub(Fountain.Conversations.TitleGenerator, :generate, fn _, _ ->
      flunk("bounded turn generated an untracked title")
    end)

    stub(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _, _, _ ->
      flunk("turn ran a separate adapter install")
    end)

    stub(Sandbox.Sprites, :spawn, fn _, program, args, opts ->
      assert program == "bash"
      assert ["-c", _, "acp-bootstrap", installer | _] = args
      assert installer =~ "@agentclientprotocol/"
      send(test, {:spawn_argv, args})
      transport = opts[:owner]
      execution = Repo.one!(TurnExecution)
      assert execution.spawn_submitted_at
      assert execution.state == "active"
      assert opts[:session_info]
      send(test, {:transport, transport})
      send(transport, {:session_info, %{ref: ref}, "live-fixture"})
      {:ok, %Command{provider: :sprites, ref: ref}}
    end)

    stub(Sandbox.Sprites, :write_stdin, fn _, data ->
      send(test, {:wrote, Jason.decode!(IO.iodata_to_binary(data))})
      :ok
    end)

    assert :ok = GenServer.call(pid, {:send_prompt, "review", []})
    assert_receive {:transport, transport}

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Fountain.ExecutionTransportSupervisor, transport)
    end)

    {pid, transport, ref, Repo.one!(TurnExecution)}
  end

  defp next_write do
    assert_receive {:wrote, message}, 2_000
    message
  end

  defp reply(transport, ref, id, result),
    do:
      send(
        transport,
        {:stdout, %{ref: ref}, Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}) <> "\n"}
      )

  defp drive_to_prompt(transport, ref) do
    %{"id" => id, "method" => "initialize"} = next_write()
    reply(transport, ref, id, %{"agentCapabilities" => %{"loadSession" => true}})
    %{"id" => id, "method" => "session/new", "params" => params} = next_write()
    assert get_in(params, ["_meta", "claudeCode", "options", "maxTurns"]) == 2
    reply(transport, ref, id, %{"sessionId" => "runtime-session", "models" => %{}})
    %{"id" => id, "method" => "session/set_model"} = next_write()
    reply(transport, ref, id, %{})
    %{"id" => id, "method" => "session/prompt"} = next_write()
    id
  end

  defp wait_idle(pid, attempts \\ 200)
  defp wait_idle(_pid, 0), do: flunk("bounded actor did not become idle")

  defp wait_idle(pid, attempts) do
    state = :sys.get_state(pid)

    if state.current_turn == nil do
      state
    else
      Process.sleep(10)
      wait_idle(pid, attempts - 1)
    end
  end
end
