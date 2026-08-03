defmodule Fountain.Conversations.ConversationServerProvisionDeadlineTest do
  # #329: a ConversationServer stuck inside provisioning was invisible to
  # every reclamation mechanism — the reaper exempts rows whose server is
  # alive, and the server's own timers queue behind the stuck
  # handle_continue. The provision watchdog is an external process that
  # kills the server at an absolute deadline and applies the same
  # failed/failed transitions as the normal provision-failure path.
  use Fountain.ConversationServerCase

  setup do
    Application.put_env(:fountain, :provision_deadline_ms, 300)
    on_exit(fn -> Application.delete_env(:fountain, :provision_deadline_ms) end)
    :ok
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(100)
        wait_until(fun, tries - 1)
    end
  end

  test "a hung provision is killed at the deadline and its rows are failed" do
    stub_happy_sprite()

    # Stall provisioning indefinitely — the shape of a step that hangs
    # without raising (e.g. a stream that stops yielding chunks).
    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      Process.sleep(:infinity)
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Fountain.Test.FakeRuntime
    ]

    {:ok, pid} = GenServer.start(Fountain.Conversations.ConversationServer, args)
    ref = Process.monitor(pid)

    # The watchdog must kill the stuck server…
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    # …and then free the quota slot by failing the rows.
    wait_until(fn ->
      Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    end)

    assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
  end

  test "a provision that completes in time is left alone" do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, _ref, :alive} = start_server(conv)

    # Outlive the deadline, then confirm the watchdog did not fire.
    Process.sleep(600)
    assert Process.alive?(pid)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"

    GenServer.call(pid, :terminate_conv, 30_000)
  end
end
