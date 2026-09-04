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

  defp rebind_to_new(ctx) do
    %{
      "agent_id" => ctx.new_agent.id,
      "environment_id" => ctx.new_env.id,
      "vault_id" => ctx.new_vault.id
    }
  end

  defp stub_started_server do
    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _spec ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)
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

  test "leaves the agent's canonical home standing, even unheld", ctx do
    # The home belongs to the agent identity, not to this conversation
    # (ADR 0023): the next ordinary launch of `old_agent` has to find it with
    # its disk intact. Destroying it here reset an agent's accumulated state
    # every time one of its conversations was reapplied.
    Repo.delete!(ctx.cotenant)
    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)
    stub_started_server()

    assert {:ok, updated} = Conversations.reapply_conversation(ctx.conv, %{})
    assert {:ok, woken} = Conversations.wake_conversation(updated.id)
    refute woken.sandbox_id == ctx.home.id
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"

    assert Conversations._unsafe_find_home(
             ctx.user.id,
             ctx.old_agent.id,
             ctx.old_env.id,
             ctx.old_vault.id
           ).id == ctx.home.id
  end

  test "retires the private home a previous reapply minted", ctx do
    Repo.delete!(ctx.cotenant)
    test = self()

    stub(Managoat.Sandbox, :destroy, fn handle ->
      send(test, {:destroyed, handle.name})
      :ok
    end)

    stub_started_server()

    assert {:ok, first} = Conversations.reapply_conversation(ctx.conv, %{})
    assert {:ok, woken} = Conversations.wake_conversation(first.id)
    private = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
    assert private.configuration_generation == first.configuration_generation
    {:ok, private} = Conversations.update_sandbox(private, %{status: "ready"})

    # A private home has one holder by construction and no launch can ever
    # find it again, so the next generation is what retires it.
    assert {:ok, second} = Conversations.reapply_conversation(woken, %{})
    assert {:ok, _} = Conversations.wake_conversation(second.id)

    assert_received {:destroyed, name}
    assert name == private.sprite_name
    assert Conversations._unsafe_get_sandbox!(private.id).status == "terminated"
  end

  test "builds the newly selected agent's sandbox mode, not the old machine's", ctx do
    ephemeral_agent =
      insert_agent(
        user_id: ctx.user.id,
        runtime: "claude",
        sandbox_mode: "ephemeral"
      )

    Repo.delete!(ctx.cotenant)
    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)
    stub_started_server()

    assert {:ok, updated} =
             Conversations.reapply_conversation(ctx.conv, %{"agent_id" => ephemeral_agent.id})

    assert {:ok, woken} = Conversations.wake_conversation(updated.id)
    assert Conversations._unsafe_get_sandbox!(woken.sandbox_id).mode == "ephemeral"
  end

  test "does not lock the old home out of a later launch of its own agent", ctx do
    # The reapplied row keeps naming the old machine until its next prompt,
    # but its runtime is already the newly selected agent's. Counting it as a
    # tenant of that machine refused every later attach of the agent whose
    # home it is, with `sandbox_runtime_mismatch`, until the reapplied
    # conversation prompted again or was terminated.
    Repo.delete!(ctx.cotenant)

    assert {:ok, updated} = Conversations.reapply_conversation(ctx.conv, rebind_to_new(ctx))
    assert updated.runtime == "codex"
    assert updated.sandbox_id == ctx.home.id
    assert Conversations._unsafe_sandbox_runtime(ctx.home.id) == nil

    assert {:ok, attached} =
             Conversations.start_conversation(%{
               "sandbox_id" => ctx.home.id,
               "agent_id" => ctx.old_agent.id,
               "user_id" => ctx.user.id,
               "vault_id" => ctx.old_vault.id
             })

    assert attached.sandbox_id == ctx.home.id
    assert attached.runtime == "claude"
  end

  test "a conversation whose agent was deleted is refused, not crashed", ctx do
    {:ok, orphan} = Conversations.update_conversation(ctx.conv, %{agent_id: nil})

    assert {:error, :no_agent} = Conversations.reapply_conversation(orphan, %{})
  end

  test "reapplies a conversation that was created without a prompt", ctx do
    # Nothing writes `idle` until a turn ends, so a promptless conversation
    # sits at `pending` for good. Refusing it made "I picked the wrong agent
    # before I sent anything" unreachable behind a 503 that never cleared.
    {:ok, promptless} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

    assert {:ok, updated} = Conversations.reapply_conversation(promptless, rebind_to_new(ctx))

    assert updated.agent_id == ctx.new_agent.id
    assert is_binary(updated.configuration_generation)
  end

  test "still refuses while a provision is in flight", ctx do
    {:ok, _} = Conversations.update_sandbox(ctx.home, %{status: "starting"})
    {:ok, provisioning} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

    assert {:error, :provisioning} = Conversations.reapply_conversation(provisioning, %{})
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
