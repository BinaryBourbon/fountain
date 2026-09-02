defmodule Fountain.Conversations.SandboxResetTest do
  # #1071: resetting a home destroys the machine and keeps the conversations;
  # each one's next prompt builds a fresh home (ADR 0023 step 5).
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        environment_id: env.id,
        provider: "sprites"
      )

    a =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: home,
        status: "idle",
        runtime_session_id: "sess-a"
      )

    b = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
    {:ok, user: user, env: env, agent: agent, home: home, a: a, b: b}
  end

  test "destroys the sprite, retires the row, keeps the conversations", ctx do
    test = self()
    stub(Managoat.Sandbox.Sprites, :destroy, fn h -> send(test, {:destroyed, h.name}) && :ok end)

    assert {:ok, sandbox} = Conversations.reset_sandbox(ctx.home, actor: "api")
    assert sandbox.status == "terminated"
    assert_received {:destroyed, name}
    assert name == ctx.home.sprite_name

    for conv <- [ctx.a, ctx.b] do
      reloaded = Conversations._unsafe_get_conversation!(conv.id)
      assert reloaded.status == "idle"
      assert reloaded.sandbox_id == ctx.home.id
      assert is_nil(reloaded.runtime_session_id)
    end
  end

  test "every conversation's transcript says the machine was reset", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    assert {:ok, _} = Conversations.reset_sandbox(ctx.home)

    for conv <- [ctx.a, ctx.b] do
      assert [event] =
               Conversations._unsafe_list_log_events(conv.id)
               |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))

      assert %{"event" => "reset", "reason" => "home_reset"} = Jason.decode!(event.data)
    end
  end

  test "a live server on the home is told the machine is gone, and nothing else", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    test = self()

    # Stand in for conversation A's ConversationServer: registered under its
    # id, forwards whatever is cast to it.
    fake =
      spawn(fn ->
        {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.a.id, nil)
        send(test, :registered)

        receive do
          {:"$gen_cast", msg} -> send(test, {:cast, msg})
        end
      end)

    assert_receive :registered
    assert {:ok, ^fake} = ConversationServer.await_registered(ctx.a.id)

    assert {:ok, _} = Conversations.reset_sandbox(ctx.home)
    assert_receive {:cast, {:machine_gone, "reset", "home_reset", message}}, 1_000
    assert message =~ "reset by its owner"

    # The server records the event on A's transcript itself; the reset does
    # not write a second one. B, with no server, gets it recorded here.
    assert Conversations._unsafe_list_log_events(ctx.a.id)
           |> Enum.filter(&(&1.stage == "sandbox")) == []

    assert [_] =
             Conversations._unsafe_list_log_events(ctx.b.id)
             |> Enum.filter(&(&1.stage == "sandbox"))
  end

  test "refused while a conversation on it is mid-turn", ctx do
    insert_turn(ctx.a, status: "running")
    assert {:error, :sandbox_mid_turn} = Conversations.reset_sandbox(ctx.home)
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
  end

  test "refused for an ephemeral sandbox and for one already gone", ctx do
    ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")

    assert {:error, {:sandbox_not_resettable, "ephemeral"}} =
             Conversations.reset_sandbox(ephemeral)

    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, gone} = Conversations.reset_sandbox(ctx.home)

    assert {:error, {:sandbox_not_resettable, "terminated"}} =
             Conversations.reset_sandbox(gone)
  end

  test "the row retires even when the provider refuses the destroy", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> {:error, :boom} end)
    assert {:ok, sandbox} = Conversations.reset_sandbox(ctx.home)
    assert sandbox.status == "terminated"
  end

  test "the next prompt builds a fresh home on the same identity", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, _} = Conversations.reset_sandbox(ctx.home)

    assert {:ok, woken} = Conversations.wake_conversation(ctx.a.id)
    refute woken.sandbox_id == ctx.home.id
    fresh = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
    assert fresh.mode == "persistent"
    assert fresh.agent_id == ctx.agent.id

    assert %{id: id} = Conversations._unsafe_find_home(ctx.user.id, ctx.agent.id, ctx.env.id, nil)
    assert id == woken.sandbox_id
    # The co-tenant followed onto the fresh home (#1067).
    assert Conversations._unsafe_get_conversation!(ctx.b.id).sandbox_id == woken.sandbox_id
  end

  test "records sandbox.reset with the actor", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, _} = Conversations.reset_sandbox(ctx.home, actor: "api", request_ip: "10.0.0.1")

    assert [event] =
             Fountain.Audit.list_for_user(ctx.user.id)
             |> Enum.filter(&(&1.action == "sandbox.reset"))

    assert event.resource_id == ctx.home.id
    assert event.actor == "api"
    assert event.metadata["conversations"] == 2
    assert event.metadata["agent_id"] == ctx.agent.id
  end
end
