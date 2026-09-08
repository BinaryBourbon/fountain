defmodule Fountain.Conversations.RunnerRecoveryTest do
  use Fountain.ConversationServerCase

  alias Fountain.Repo

  defp fixture(online? \\ true) do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, permission_policy: %{"default" => "ask"})
    sandbox = insert_sandbox(user_id: user.id, provider: "runner", status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "running",
        runtime_session_id: "live-session"
      )

    turn = insert_turn(conv, %{status: "running", acp_prompt_id: 4, prompt: "write one nonce"})
    stub_happy_sprite()
    test = self()
    online = start_supervised!({Agent, fn -> online? end})

    Mimic.stub(Managoat.Sandbox, :get, fn _ ->
      if Agent.get(online, & &1),
        do: {:ok, %{status: :running}},
        else: {:error, {:unavailable, :runner_offline}}
    end)

    Mimic.stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)
    Mimic.stub(Managoat.Sandbox, :write_file, fn _, _, _, _ -> :ok end)

    Mimic.stub(Managoat.Sandbox, :list_sessions, fn _ ->
      {:ok,
       [
         %Managoat.Sandbox.Session{
           id: "live-command",
           command: "env FOUNTAIN_CONVERSATION_ID=#{conv.id} claude-agent-acp"
         }
       ]}
    end)

    Mimic.stub(Managoat.Sandbox, :attach, fn _, "live-command", _ ->
      ref = make_ref()
      send(test, {:attached, ref})
      boundary = Jason.encode!(%{jsonrpc: "2.0", id: 3, result: %{}}) <> "\n"
      send(self(), {:stdout, %{ref: ref}, boundary})
      {:ok, %Managoat.Sandbox.Command{provider: :runner, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox, :write_stdin, fn _, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox, :close_stdin, fn _ -> send(test, :closed_stdin) && :ok end)
    Mimic.stub(Managoat.Sandbox, :stop_command, fn _ -> send(test, :stopped_command) && :ok end)

    {pid, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid, conv: conv, turn: turn, online: online}
  end

  defp settle(pid) do
    state = :sys.get_state(pid)
    if state.acp_peer, do: :sys.get_state(state.acp_peer)
    :sys.get_state(pid)
  end

  defp permission(pid, ref) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "session/request_permission",
      "params" => %{
        "toolCall" => %{"toolCallId" => "nonce", "title" => "write nonce", "kind" => "edit"},
        "options" => [%{"optionId" => "allow", "kind" => "allow_once"}]
      }
    }

    send(pid, {:stdout, %{ref: ref}, Jason.encode!(message) <> "\n"})
    settle(pid).current_turn.pending_permission
  end

  test "disconnect preserves the accepted turn and its pending permission, then reattaches once" do
    f = fixture()
    assert_receive {:attached, old_ref}
    pending = permission(f.pid, old_ref)
    assert pending["request_id"]
    Agent.update(f.online, fn _ -> false end)
    send(f.pid, {:error, %{ref: old_ref}, :runner_disconnected})
    waiting = settle(f.pid)
    assert waiting.current_turn.id == f.turn.id
    assert Repo.reload!(f.turn).status == "running"
    assert Repo.reload!(f.turn).pending_permission == pending
    assert GenServer.call(f.pid, {:send_prompt, "duplicate", []}) == {:error, :busy}
    refute_receive :closed_stdin
    refute_receive :stopped_command

    Agent.update(f.online, fn _ -> true end)
    send(f.pid, {:runner_reconnect, waiting.runner_reconnect.token})
    assert_receive {:attached, ref}, 1_000
    assert ref != old_ref
    assert permission(f.pid, ref)["request_id"] == pending["request_id"]
    assert GenServer.call(f.pid, {:answer_permission, pending["request_id"], "allow"}) == :ok
    assert_receive {:wrote, answer}
    assert Jason.decode!(answer)["id"] == 5

    # An old connection's late error must not fail the replacement command.
    send(f.pid, {:error, %{ref: old_ref}, :runner_disconnected})
    response = Jason.encode!(%{jsonrpc: "2.0", id: 4, result: %{stopReason: "end_turn"}})
    send(f.pid, {:stdout, %{ref: ref}, response <> "\n"})
    settle(f.pid)
    assert Repo.reload!(f.turn).status == "completed"
    assert [%{id: id}] = Conversations._unsafe_list_turns(f.conv.id)
    assert id == f.turn.id
    assert :sys.get_state(f.pid).runner_reconnect == nil
  end

  test "boot before the runner reconnects retains the running turn until attachment" do
    f = fixture(false)
    waiting = :sys.get_state(f.pid)
    assert waiting.runner_reconnect
    assert waiting.current_turn.id == f.turn.id
    assert Repo.reload!(f.turn).status == "running"
    Agent.update(f.online, fn _ -> true end)
    send(f.pid, {:runner_reconnect, waiting.runner_reconnect.token})
    assert_receive {:attached, _}, 1_000
    assert settle(f.pid).current_turn.id == f.turn.id
    assert :sys.get_state(f.pid).runner_reconnect == nil
  end

  test "an expired reconnect deadline ends the turn and clears busy state" do
    f = fixture()
    assert_receive {:attached, ref}
    send(f.pid, {:error, %{ref: ref}, :runner_disconnected})
    waiting = settle(f.pid)

    :sys.replace_state(f.pid, fn state ->
      put_in(state.runner_reconnect.deadline, System.monotonic_time(:millisecond) - 1)
    end)

    send(f.pid, {:runner_reconnect, waiting.runner_reconnect.token})
    state = settle(f.pid)
    assert state.current_turn == nil
    assert state.runner_reconnect == nil
    assert Repo.reload!(f.turn).status == "failed"
  end

  test "a reconnect blocked after a runner disconnect expires its own attempt" do
    f = fixture()
    assert_receive {:attached, ref}
    first = settle(f.pid)
    startup = Repo.get!(Conversations.ActorStartup, first.actor_startup_id)
    assert startup.state == "completed"
    send(f.pid, {:error, %{ref: ref}, :runner_disconnected})
    waiting = settle(f.pid)
    assert waiting.runner_reconnect

    # Keep the real disconnect path; shorten only its two-minute recovery clock.
    :sys.replace_state(f.pid, fn state ->
      %{
        state
        | runner_reconnect: %{
            state.runner_reconnect
            | deadline: System.monotonic_time(:millisecond) + 300,
              deadline_at: DateTime.add(DateTime.utc_now(), 300, :millisecond)
          }
      }
    end)

    owner = self()

    Mimic.stub(Managoat.Sandbox, :get, fn _ ->
      send(owner, :blocked_reconnect)
      Process.sleep(:infinity)
    end)

    Mimic.stub(Horde.DynamicSupervisor, :terminate_child, fn _, pid ->
      Process.exit(pid, :kill)
      :ok
    end)

    monitor = Process.monitor(f.pid)
    send(f.pid, {:runner_reconnect, waiting.runner_reconnect.token})
    assert_receive :blocked_reconnect, 1_000
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
    assert Repo.reload!(startup) == startup
    assert Repo.reload!(f.turn).status == "running"
    assert Repo.get!(Conversations.ActorClaim, first.actor_claim).state == "active"

    assert Repo.one!(
             from s in Conversations.ActorStartup,
               where: s.actor_claim_id == ^first.actor_claim and s.id != ^startup.id
           ).state == "expired"

    refute Conversations.ActorStartups.writable?(first.actor_claim)
    refute_receive :stopped_command
  end

  test "interrupt cancels recovery and a late retry cannot resurrect its turn" do
    f = fixture()
    assert_receive {:attached, ref}
    send(f.pid, {:error, %{ref: ref}, :runner_disconnected})
    waiting = settle(f.pid)
    assert GenServer.call(f.pid, :interrupt) == :ok
    send(f.pid, {:runner_reconnect, waiting.runner_reconnect.token})
    assert settle(f.pid).current_turn == nil
    assert Repo.reload!(f.turn).status == "interrupted"
    refute_receive {:attached, _}
  end

  test "other transport failures retain terminal behavior" do
    f = fixture()
    assert_receive {:attached, ref}
    send(f.pid, {:error, %{ref: ref}, :protocol_failure})
    assert settle(f.pid).current_turn == nil
    assert Repo.reload!(f.turn).status == "failed"
  end

  test "permission expiry while disconnected ends recovery without granting the request" do
    f = fixture()
    assert_receive {:attached, ref}
    pending = permission(f.pid, ref)
    send(f.pid, {:error, %{ref: ref}, :runner_disconnected})
    settle(f.pid)
    send(f.pid, {:permission_timeout, pending["request_id"]})
    assert settle(f.pid).runner_reconnect == nil
    turn = Repo.reload!(f.turn)
    assert turn.status == "failed"
    assert turn.pending_permission == nil
    refute_receive {:wrote, _}
  end
end
