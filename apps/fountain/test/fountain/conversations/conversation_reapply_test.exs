defmodule Fountain.Conversations.ConversationReapplyTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Conversations}

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    old_env = insert_env(user_id: user.id)
    new_env = insert_env(user_id: user.id)
    old_vault = insert_vault(user_id: user.id)
    new_vault = insert_vault(user_id: user.id)

    old_agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        sandbox_mode: "persistent",
        environment_id: old_env.id,
        allowed_vault_ids: [old_vault.id]
      )

    new_agent =
      insert_agent(
        user_id: user.id,
        runtime: "codex",
        sandbox_mode: "persistent",
        environment_id: new_env.id,
        allowed_environment_ids: [new_env.id],
        allowed_vault_ids: [new_vault.id]
      )

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: old_agent.id,
        environment_id: old_env.id,
        vault_id: old_vault.id
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: old_agent,
        agent_version_id: Agents._unsafe_current_version_id(old_agent.id),
        sandbox: home,
        vault_id: old_vault.id,
        runtime_session_id: "session-before-reapply",
        status: "idle",
        title: "Keep this thread"
      )

    cotenant =
      insert_conversation(
        user_id: user.id,
        agent: old_agent,
        sandbox: home,
        vault_id: old_vault.id,
        status: "idle"
      )

    {:ok,
     user: user,
     old_env: old_env,
     new_env: new_env,
     old_vault: old_vault,
     new_vault: new_vault,
     old_agent: old_agent,
     new_agent: new_agent,
     home: home,
     conv: conv,
     cotenant: cotenant}
  end

  test "an empty reapply keeps the selection and forces a fresh private home", ctx do
    turn = insert_turn(ctx.conv, status: "completed", prompt: "remember this")

    assert {:ok, updated} =
             Conversations.reapply_conversation(ctx.conv, %{},
               actor: "api",
               request_ip: "10.0.0.1"
             )

    assert updated.id == ctx.conv.id
    assert updated.title == "Keep this thread"
    assert updated.agent_id == ctx.old_agent.id
    assert updated.vault_id == ctx.old_vault.id
    assert updated.environment_id == nil
    assert updated.sandbox_id == ctx.home.id
    assert is_binary(updated.configuration_generation)
    assert updated.runtime_session_id == nil
    assert Conversations._unsafe_list_turns(updated.id) |> Enum.map(& &1.id) == [turn.id]

    [stage] =
      Conversations._unsafe_list_log_events(updated.id)
      |> Enum.filter(&(&1.kind == "stage" and &1.stage == "configuration"))

    assert %{"event" => "reapplied", "message" => message} = Jason.decode!(stage.data)
    assert message =~ "next prompt builds a fresh machine"

    [audit] =
      Fountain.Audit.list_for_user(ctx.user.id)
      |> Enum.filter(&(&1.action == "conversation.configuration_reapplied"))

    assert audit.actor == "api"
    assert audit.request_ip == "10.0.0.1"
    assert audit.metadata["current"]["agent_id"] == ctx.old_agent.id

    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _spec ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    assert {:ok, woken} = Conversations.wake_conversation(updated.id)
    refute woken.sandbox_id == ctx.home.id

    fresh = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
    assert fresh.mode == "persistent"
    assert fresh.agent_id == ctx.old_agent.id
    assert fresh.environment_id == ctx.old_env.id
    assert fresh.vault_id == ctx.old_vault.id
    assert fresh.configuration_generation == updated.configuration_generation

    # The canonical home and its other conversation were not reset or moved.
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
    assert Conversations._unsafe_get_conversation!(ctx.cotenant.id).sandbox_id == ctx.home.id

    assert Conversations._unsafe_find_home(
             ctx.user.id,
             ctx.old_agent.id,
             ctx.old_env.id,
             ctx.old_vault.id
           ).id == ctx.home.id

    assert Conversations._unsafe_find_home(
             ctx.user.id,
             ctx.old_agent.id,
             ctx.old_env.id,
             ctx.old_vault.id,
             updated.configuration_generation
           ).id == fresh.id
  end

  test "rebinds the Agent, Environment and Vault together", ctx do
    assert {:ok, updated} =
             Conversations.reapply_conversation(ctx.conv, %{
               "agent_id" => ctx.new_agent.id,
               "environment_id" => ctx.new_env.id,
               "vault_id" => ctx.new_vault.id
             })

    assert updated.agent_id == ctx.new_agent.id
    assert updated.agent_version_id == Agents._unsafe_current_version_id(ctx.new_agent.id)
    assert updated.runtime == "codex"
    assert updated.environment_id == ctx.new_env.id
    assert updated.vault_id == ctx.new_vault.id
    assert updated.runtime_session_id == nil
    assert updated.sandbox_id == ctx.home.id
    assert is_binary(updated.configuration_generation)
  end

  test "retires an old persistent home when this conversation was its only holder", ctx do
    Repo.delete!(ctx.cotenant)
    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _spec ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    assert {:ok, updated} = Conversations.reapply_conversation(ctx.conv, %{})
    assert {:ok, woken} = Conversations.wake_conversation(updated.id)
    refute woken.sandbox_id == ctx.home.id
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
  end

  test "explicit null clears the Environment override and Vault", ctx do
    {:ok, with_override} =
      Conversations.update_conversation(ctx.conv, %{
        environment_id: ctx.old_env.id,
        vault_id: ctx.old_vault.id
      })

    assert {:ok, updated} =
             Conversations.reapply_conversation(with_override, %{
               "environment_id" => nil,
               "vault_id" => nil
             })

    assert updated.environment_id == nil
    assert updated.vault_id == nil
  end

  test "refuses foreign and disallowed resources without changing the conversation", ctx do
    other = insert_active_user()
    foreign_agent = insert_agent(user_id: other.id)

    assert {:error, :not_found} =
             Conversations.reapply_conversation(ctx.conv, %{"agent_id" => foreign_agent.id})

    locked_agent =
      insert_agent(
        user_id: ctx.user.id,
        allowed_vault_ids: [],
        allowed_environment_ids: []
      )

    assert {:error, :vault_not_allowed} =
             Conversations.reapply_conversation(ctx.conv, %{
               "agent_id" => locked_agent.id,
               "vault_id" => ctx.new_vault.id
             })

    unchanged = Conversations._unsafe_get_conversation!(ctx.conv.id)
    assert unchanged.agent_id == ctx.old_agent.id
    assert unchanged.vault_id == ctx.old_vault.id
    assert unchanged.runtime_session_id == "session-before-reapply"
    assert unchanged.configuration_generation == nil
  end

  test "refuses a running turn without changing anything", ctx do
    insert_turn(ctx.conv, status: "running")

    assert {:error, :conversation_busy} =
             Conversations.reapply_conversation(ctx.conv, %{})

    unchanged = Conversations._unsafe_get_conversation!(ctx.conv.id)
    assert unchanged.runtime_session_id == "session-before-reapply"
    assert unchanged.configuration_generation == nil
  end
end
