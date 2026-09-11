defmodule Fountain.Conversations.ConversationServerRefreshTest do
  @moduledoc """
  `refresh_configuration/2`, and the revision that stops a server starting a
  turn on a selection it has not read (#1565).
  """

  use Fountain.ConversationServerCase

  alias Fountain.Environments

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "pending",
        agent_id: agent.id,
        environment_id: env.id
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        runtime: "claude",
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  test "an idle server re-applies the row and keeps its machine", ctx do
    stub_happy_sprite()
    test = self()
    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

    {pid, _ref, :alive} = start_server(ctx.conv)
    assert :ok = GenServer.call(pid, :refresh_configuration)

    # The machine is the whole point of the operation: it stays, and so does
    # everything the agent put on its disk.
    refute_received :destroyed
    assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).status == "ready"
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a delayed notification for the revision already loaded is a no-op", ctx do
    stub_happy_sprite()
    {pid, _ref, :alive} = start_server(ctx.conv)

    revision = :sys.get_state(pid).configuration_revision
    assert :ok = GenServer.call(pid, {:refresh_configuration, revision})
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a server with a running turn refuses", ctx do
    stub_happy_sprite()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

    {pid, _monitor, :alive} = start_server(ctx.conv, initial_prompt: "first")
    assert {:error, :conversation_busy} = GenServer.call(pid, :refresh_configuration)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a server holding no machine has nothing to do", ctx do
    stub_happy_sprite()
    {pid, _ref, :alive} = start_server(ctx.conv)
    :sys.replace_state(pid, fn state -> %{state | handle: nil} end)

    assert :ok = GenServer.call(pid, :refresh_configuration)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a prompt reloads configuration when the refresh notification was missed", ctx do
    stub_happy_sprite()
    {pid, _, :alive} = start_server(ctx.conv)

    # The harness server is deliberately outside the registry, so a reapply can
    # commit while it is alive without any notification reaching it.
    {:ok, conv} = Conversations.update_conversation(ctx.conv, %{status: "idle"})

    {:ok, _} =
      Environments.update_environment(ctx.env, %{env_vars: %{"REAPPLY_MARKER" => "fresh"}})

    test = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, opts ->
      send(test, {:spawned, opts[:env]})
      {:error, {:unavailable, :test_finished}}
    end)

    assert {:ok, updated} = Conversations.reapply_conversation(conv, %{})
    assert :sys.get_state(pid).configuration_revision == 0

    assert :ok = GenServer.call(pid, {:send_prompt, "after reapply", []})
    state = :sys.get_state(pid)
    assert state.configuration_revision == updated.configuration_revision

    assert_received {:spawned, env}
    assert {"REAPPLY_MARKER", "fresh"} in env
    assert [turn] = Conversations._unsafe_list_turns(conv.id)
    assert turn.prompt == "after reapply"
  end
end
