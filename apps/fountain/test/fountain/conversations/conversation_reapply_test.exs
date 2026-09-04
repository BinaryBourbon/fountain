defmodule Fountain.Conversations.ConversationReapplyTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.Reapply

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    old_env = insert_env(user_id: user.id)
    old_vault = insert_vault(user_id: user.id)
    new_vault = insert_vault(user_id: user.id)

    # Same build inputs as old_env, so selecting it needs no rebuild. Only
    # the variables differ, and those reach the machine on the next spawn.
    sibling_env =
      insert_env(
        user_id: user.id,
        packages: old_env.packages,
        repositories: old_env.repositories,
        setup_script: old_env.setup_script,
        env_vars: %{"WHO" => "sibling"}
      )

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        environment_id: old_env.id,
        allowed_environment_ids: [old_env.id, sibling_env.id],
        allowed_vault_ids: [old_vault.id, new_vault.id]
      )

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "ephemeral",
        agent_id: agent.id,
        environment_id: old_env.id,
        vault_id: old_vault.id,
        build_fingerprint: Reapply.fingerprint(old_env)
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        agent_version_id: Agents._unsafe_current_version_id(agent.id),
        sandbox: sandbox,
        vault_id: old_vault.id,
        runtime_session_id: "session-before-reapply",
        status: "idle",
        title: "Keep this thread"
      )

    {:ok,
     user: user,
     old_env: old_env,
     sibling_env: sibling_env,
     old_vault: old_vault,
     new_vault: new_vault,
     agent: agent,
     sandbox: sandbox,
     conv: conv}
  end

  describe "applying a selection to the machine that is already there" do
    test "keeps the conversation, the transcript and the machine", ctx do
      turn = insert_turn(ctx.conv, status: "completed", prompt: "remember this")

      assert {:ok, updated} =
               Conversations.reapply_conversation(ctx.conv, %{},
                 actor: "api",
                 request_ip: "10.0.0.1"
               )

      assert updated.id == ctx.conv.id
      assert updated.title == "Keep this thread"
      # The machine is the point: reapply does not move the conversation off
      # it, so whatever the agent has on disk is still there.
      assert updated.sandbox_id == ctx.sandbox.id
      assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).status == "ready"
      assert Conversations._unsafe_list_turns(updated.id) |> Enum.map(& &1.id) == [turn.id]

      [stage] =
        Conversations._unsafe_list_log_events(updated.id)
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "configuration"))

      assert stage.state == "done"
    end

    test "records the agent's current version", ctx do
      {:ok, _} = Agents.update_agent(ctx.agent, %{system: "a new persona"})
      newest = Agents._unsafe_current_version_id(ctx.agent.id)
      refute newest == ctx.conv.agent_version_id

      assert {:ok, updated} = Conversations.reapply_conversation(ctx.conv, %{})
      assert updated.agent_version_id == newest
    end

    test "rebinds the Vault, and an explicit null clears it", ctx do
      assert {:ok, updated} =
               Conversations.reapply_conversation(ctx.conv, %{"vault_id" => ctx.new_vault.id})

      assert updated.vault_id == ctx.new_vault.id
      assert updated.sandbox_id == ctx.sandbox.id

      assert {:ok, cleared} =
               Conversations.reapply_conversation(updated, %{"vault_id" => nil})

      assert cleared.vault_id == nil
    end

    test "rebinds to an environment that builds the machine the same way", ctx do
      assert {:ok, updated} =
               Conversations.reapply_conversation(ctx.conv, %{
                 "environment_id" => ctx.sibling_env.id
               })

      assert updated.environment_id == ctx.sibling_env.id
      assert updated.sandbox_id == ctx.sandbox.id
    end

    test "tells the live server to apply it, and keeps the runtime session", ctx do
      test = self()

      stub(Fountain.Conversations.ConversationServer, :refresh_configuration, fn id ->
        send(test, {:refreshed, id})
        :ok
      end)

      assert {:ok, updated} = Conversations.reapply_conversation(ctx.conv, %{})
      assert_received {:refreshed, id}
      assert id == ctx.conv.id

      # Nothing clears it here. The machine survives, so the runtime session
      # on its disk is still resumable until the server drops the connection.
      assert updated.runtime_session_id == "session-before-reapply"
    end
  end

  describe "a selection that would need the disk rebuilt" do
    test "refuses a runtime change and names it", ctx do
      codex =
        insert_agent(
          user_id: ctx.user.id,
          runtime: "codex",
          environment_id: ctx.old_env.id,
          allowed_vault_ids: [ctx.old_vault.id]
        )

      assert {:error, {:rebuild_required, :runtime}} =
               Conversations.reapply_conversation(ctx.conv, %{"agent_id" => codex.id})

      unchanged = Conversations._unsafe_get_conversation!(ctx.conv.id)
      assert unchanged.agent_id == ctx.agent.id
      assert unchanged.runtime == "claude"
    end

    test "refuses an environment whose build inputs differ, and names the field", ctx do
      rebuilt =
        insert_env(
          user_id: ctx.user.id,
          setup_script: "echo a genuinely different setup",
          packages: ctx.old_env.packages,
          repositories: ctx.old_env.repositories
        )

      {:ok, agent} =
        Agents.update_agent(ctx.agent, %{
          allowed_environment_ids: [ctx.old_env.id, rebuilt.id]
        })

      conv = Conversations._unsafe_get_conversation!(ctx.conv.id)

      assert {:error, {:rebuild_required, :setup_script}} =
               Conversations.reapply_conversation(conv, %{"environment_id" => rebuilt.id})

      assert Conversations._unsafe_get_conversation!(conv.id).environment_id == nil
      assert agent.id == ctx.agent.id
    end

    test "refuses a networking change, because egress rules are written once", ctx do
      restricted =
        insert_env(
          user_id: ctx.user.id,
          packages: ctx.old_env.packages,
          repositories: ctx.old_env.repositories,
          setup_script: ctx.old_env.setup_script,
          networking_type: "limited",
          networking_config: %{"allow" => ["example.com"]}
        )

      {:ok, _} =
        Agents.update_agent(ctx.agent, %{
          allowed_environment_ids: [ctx.old_env.id, restricted.id]
        })

      conv = Conversations._unsafe_get_conversation!(ctx.conv.id)

      assert {:error, {:rebuild_required, :networking}} =
               Conversations.reapply_conversation(conv, %{"environment_id" => restricted.id})
    end

    test "refuses to reconfigure a machine other conversations share", ctx do
      home =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          mode: "persistent",
          agent_id: ctx.agent.id,
          environment_id: ctx.old_env.id,
          vault_id: ctx.old_vault.id,
          build_fingerprint: Reapply.fingerprint(ctx.old_env)
        )

      {:ok, conv} = Conversations.update_conversation(ctx.conv, %{sandbox_id: home.id})

      _cotenant =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: home,
          vault_id: ctx.old_vault.id,
          status: "idle"
        )

      # Skills, instructions and .mcp.json are per-machine paths, so changing
      # the vault here would change it for the cotenant too.
      assert {:error, {:rebuild_required, :shared_sandbox}} =
               Conversations.reapply_conversation(conv, %{"vault_id" => ctx.new_vault.id})

      # The refresh its cotenants would want anyway is still allowed.
      assert {:ok, refreshed} = Conversations.reapply_conversation(conv, %{})
      assert refreshed.sandbox_id == home.id
    end

    test "explains every blocker it can report", _ctx do
      for field <- [
            :runtime,
            :packages,
            :repositories,
            :setup_script,
            :networking,
            :environment,
            :shared_sandbox
          ] do
        assert is_binary(Reapply.explain(field))
      end
    end
  end

  describe "refusals that change nothing" do
    test "foreign and disallowed resources", ctx do
      other = insert_active_user()
      foreign_agent = insert_agent(user_id: other.id)

      assert {:error, :not_found} =
               Conversations.reapply_conversation(ctx.conv, %{"agent_id" => foreign_agent.id})

      locked_agent =
        insert_agent(
          user_id: ctx.user.id,
          runtime: "claude",
          allowed_vault_ids: [],
          allowed_environment_ids: []
        )

      assert {:error, :vault_not_allowed} =
               Conversations.reapply_conversation(ctx.conv, %{
                 "agent_id" => locked_agent.id,
                 "vault_id" => ctx.new_vault.id
               })

      unchanged = Conversations._unsafe_get_conversation!(ctx.conv.id)
      assert unchanged.agent_id == ctx.agent.id
      assert unchanged.vault_id == ctx.old_vault.id
    end

    test "a running turn", ctx do
      insert_turn(ctx.conv, status: "running")

      assert {:error, :conversation_busy} = Conversations.reapply_conversation(ctx.conv, %{})
      assert Conversations._unsafe_get_conversation!(ctx.conv.id).vault_id == ctx.old_vault.id
    end

    test "a conversation whose agent was deleted is refused, not crashed", ctx do
      {:ok, orphan} = Conversations.update_conversation(ctx.conv, %{agent_id: nil})

      assert {:error, :no_agent} = Conversations.reapply_conversation(orphan, %{})
    end
  end

  describe "a conversation that has not run a turn yet" do
    test "is reapplicable once its machine is ready", ctx do
      # Nothing writes `idle` until a turn ends, so a conversation created
      # without a prompt sits at `pending` for good. Refusing it made "I
      # picked the wrong agent before I sent anything" unreachable.
      {:ok, promptless} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

      assert {:ok, updated} =
               Conversations.reapply_conversation(promptless, %{"vault_id" => ctx.new_vault.id})

      assert updated.vault_id == ctx.new_vault.id
    end

    test "is refused while its machine is still being built", ctx do
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "starting"})
      {:ok, provisioning} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

      assert {:error, :provisioning} = Conversations.reapply_conversation(provisioning, %{})
    end
  end

  describe "fingerprint/1" do
    test "is stable across reads and blind to variables", ctx do
      assert Reapply.fingerprint(ctx.old_env) == Reapply.fingerprint(ctx.old_env)
      assert Reapply.fingerprint(nil) == "none"

      {:ok, revarred} =
        Fountain.Environments.update_environment(ctx.old_env, %{
          "env_vars" => %{"ANYTHING" => "else"}
        })

      assert Reapply.fingerprint(revarred) == Reapply.fingerprint(ctx.old_env)
    end

    test "changes when a build input does", ctx do
      {:ok, rebuilt} =
        Fountain.Environments.update_environment(ctx.old_env, %{
          "setup_script" => "echo different"
        })

      refute Reapply.fingerprint(rebuilt) == Reapply.fingerprint(ctx.old_env)
    end
  end
end
