defmodule Fountain.TeamTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Audit, Conversations, Team}
  alias Fountain.Conversations.ConversationServer

  # A conversation bound to the team channel, the way add_teammate leaves one.
  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp inert_start_child do
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "list_teammates/1" do
    test "one entry per agent, only channel-bound conversations, tenant-scoped" do
      user = insert_verified_user()
      other = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      linus = insert_agent(user_id: user.id, name: "Linus")
      _plain = insert_conversation(user_id: user.id, agent: ada)
      insert_teammate_conv(user, ada)
      insert_teammate_conv(user, linus)
      insert_teammate_conv(other, insert_agent(user_id: other.id))

      names = user.id |> Team.list_teammates() |> Enum.map(& &1.agent.name) |> Enum.sort()
      assert names == ["Ada", "Linus"]
    end

    test "prefers the newest live conversation over a newer terminated one" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      live = insert_teammate_conv(user, ada, status: "idle")
      _dead = insert_teammate_conv(user, ada, status: "terminated")

      assert [%{conversation: %{id: id}}] = Team.list_teammates(user.id)
      assert id == live.id
    end

    test "falls back to the terminated conversation when nothing is live" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      dead = insert_teammate_conv(user, ada, status: "terminated")

      assert [%{conversation: %{id: id}}] = Team.list_teammates(user.id)
      assert id == dead.id
      refute Team.live?(dead)
    end

    test "carries the last turn for the roster preview" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)
      insert_turn(conv, prompt: "first", turn_number: 1)
      insert_turn(conv, prompt: "second", turn_number: 2)

      assert [%{last_turn: %{prompt: "second"}}] = Team.list_teammates(user.id)
    end
  end

  describe "add_teammate/4" do
    test "opens a channel-bound conversation and records the membership" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      assert {:ok, conv} = Team.add_teammate(user.id, agent.id, %{}, actor: "ui")
      assert conv.channel_id == Team.channel()
      assert conv.agent_id == agent.id
      assert [%{agent: %{id: id}}] = Team.list_teammates(user.id)
      assert id == agent.id

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "team.member.added" in actions
    end

    test "is idempotent: a second add returns the same conversation and records nothing" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      {:ok, first} = Team.add_teammate(user.id, agent.id)
      before = length(Audit.list_recent_for_user(user.id, 50))

      assert {:ok, again} = Team.add_teammate(user.id, agent.id)
      assert again.id == first.id
      assert length(Audit.list_recent_for_user(user.id, 50)) == before
    end

    test "refuses another tenant's agent" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: other.id)

      assert {:error, :not_found} = Team.add_teammate(user.id, agent.id)
    end

    test "a name, an environment and a vault land on the conversation" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, name: "Ada")
      env = insert_env(user_id: user.id, name: "staging")
      vault = insert_vault(user_id: user.id, name: "ada-keys")
      inert_start_child()

      assert {:ok, conv} =
               Team.add_teammate(user.id, agent.id, %{
                 "name" => "  Ada (staging)  ",
                 "environment_id" => env.id,
                 "vault_id" => vault.id
               })

      assert conv.title == "Ada (staging)"
      assert conv.environment_id == env.id
      assert conv.vault_id == vault.id
      # The sandbox was provisioned from the override, not the agent's own.
      assert Repo.reload(conv.sandbox).environment_id == env.id

      assert [%{name: "Ada (staging)", agent: %{name: "Ada"}}] = Team.list_teammates(user.id)
    end

    test "a blank name means the agent's name; blank ids mean the defaults" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, name: "Ada")
      inert_start_child()

      assert {:ok, conv} =
               Team.add_teammate(user.id, agent.id, %{
                 "name" => "   ",
                 "environment_id" => "",
                 "vault_id" => ""
               })

      assert conv.title == nil
      assert conv.environment_id == nil
      assert conv.vault_id == nil
      assert [%{name: "Ada"}] = Team.list_teammates(user.id)
    end

    test "the agent's allowlists gate the environment and the vault" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)

      agent =
        insert_agent(user_id: user.id, allowed_environment_ids: [], allowed_vault_ids: [])

      assert {:error, :environment_not_allowed} =
               Team.add_teammate(user.id, agent.id, %{"environment_id" => env.id})

      assert {:error, :vault_not_allowed} =
               Team.add_teammate(user.id, agent.id, %{"vault_id" => vault.id})

      assert Team.list_teammates(user.id) == []
    end

    test "another tenant's environment or vault reads as not found" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      env = insert_env(user_id: other.id)
      vault = insert_vault(user_id: other.id)

      assert {:error, :environment_not_found} =
               Team.add_teammate(user.id, agent.id, %{"environment_id" => env.id})

      assert {:error, :vault_not_found} =
               Team.add_teammate(user.id, agent.id, %{"vault_id" => vault.id})
    end

    test "an agent already on the team keeps its conversation, whatever the new attrs" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      inert_start_child()

      {:ok, first} = Team.add_teammate(user.id, agent.id, %{"name" => "One"})

      assert {:ok, again} =
               Team.add_teammate(user.id, agent.id, %{"name" => "Two", "vault_id" => vault.id})

      assert again.id == first.id
      assert [%{name: "One"}] = Team.list_teammates(user.id)
    end
  end

  describe "addable_options/2" do
    test "the user's environments and vaults, narrowed by the agent's allowlists" do
      user = insert_verified_user()
      own = insert_env(user_id: user.id, name: "own")
      allowed = insert_env(user_id: user.id, name: "allowed")
      _other = insert_env(user_id: user.id, name: "other")
      _foreign = insert_env(user_id: insert_verified_user().id, name: "foreign")
      v1 = insert_vault(user_id: user.id, name: "v1")
      _v2 = insert_vault(user_id: user.id, name: "v2")

      open = insert_agent(user_id: user.id, environment_id: own.id)
      assert %{environments: envs, vaults: vaults} = Team.addable_options(user.id, open)
      assert envs |> Enum.map(& &1.name) |> Enum.sort() == ["allowed", "other", "own"]
      assert vaults |> Enum.map(& &1.name) |> Enum.sort() == ["v1", "v2"]

      narrow =
        insert_agent(
          user_id: user.id,
          environment_id: own.id,
          allowed_environment_ids: [allowed.id],
          allowed_vault_ids: [v1.id]
        )

      assert %{environments: envs, vaults: vaults} = Team.addable_options(user.id, narrow)
      # The agent's own environment is always offered — naming it is not an override.
      assert envs |> Enum.map(& &1.name) |> Enum.sort() == ["allowed", "own"]
      assert Enum.map(vaults, & &1.name) == ["v1"]

      closed = insert_agent(user_id: user.id, allowed_environment_ids: [], allowed_vault_ids: [])
      assert %{environments: [], vaults: []} = Team.addable_options(user.id, closed)
    end
  end

  describe "remove_teammate/3" do
    test "unbinds every team conversation for the agent, terminates the live one, records" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      old = insert_teammate_conv(user, ada, status: "terminated")
      live = insert_teammate_conv(user, ada, status: "idle")

      assert :ok = Team.remove_teammate(user.id, ada.id, actor: "ui")

      assert Team.list_teammates(user.id) == []
      assert Repo.reload(old).channel_id == nil
      assert Repo.reload(live).channel_id == nil
      # The rows survive in the user's history; the live one is now stopped.
      assert Repo.reload(live).status == "terminated"

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "team.member.removed" in actions
      # The terminate is how removal is carried out, not a second action.
      refute "conversation.terminated" in actions
    end

    test "not on the team → :not_found and no record" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      before = length(Audit.list_recent_for_user(user.id, 50))
      assert {:error, :not_found} = Team.remove_teammate(user.id, agent.id)
      assert length(Audit.list_recent_for_user(user.id, 50)) == before
    end
  end

  describe "send_message/5" do
    test "a live teammate gets the prompt through the conversation server" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, status: "idle")
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn id, text, images, _opts ->
        send(test_pid, {:sent, id, text, images})
        :ok
      end)

      assert {:ok, %{id: id}} = Team.send_message(user.id, ada.id, "hello")
      assert id == conv.id
      assert_received {:sent, ^id, "hello", []}
    end

    test "a terminated teammate gets a fresh conversation seeded with the message" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      dead = insert_teammate_conv(user, ada, status: "terminated")
      inert_start_child()

      assert {:ok, fresh} = Team.send_message(user.id, ada.id, "are you there?")
      refute fresh.id == dead.id
      assert fresh.channel_id == Team.channel()

      # The roster now shows the new conversation for the same teammate.
      assert [%{agent: %{id: agent_id}, conversation: %{id: conv_id}}] =
               Team.list_teammates(user.id)

      assert agent_id == ada.id
      assert conv_id == fresh.id
    end

    test "a fresh conversation inherits the teammate's name, environment and vault" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)

      _dead =
        insert_teammate_conv(user, ada,
          status: "terminated",
          title: "Ada (staging)",
          environment_id: env.id,
          vault_id: vault.id
        )

      inert_start_child()

      assert {:ok, fresh} = Team.send_message(user.id, ada.id, "are you there?")
      assert fresh.title == "Ada (staging)"
      assert fresh.environment_id == env.id
      assert fresh.vault_id == vault.id
      assert Repo.reload(fresh.sandbox).environment_id == env.id
      assert [%{name: "Ada (staging)"}] = Team.list_teammates(user.id)
    end

    test "a server that answers :gone also gets a fresh conversation" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      stale = insert_teammate_conv(user, ada, status: "idle")
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :gone} end)
      inert_start_child()

      assert {:ok, fresh} = Team.send_message(user.id, ada.id, "hello?")
      refute fresh.id == stale.id
    end

    test "other errors pass through unchanged" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada, status: "running")
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)

      assert {:error, :busy} = Team.send_message(user.id, ada.id, "hello")
    end

    test "not on the team → :not_found" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      assert {:error, :not_found} = Team.send_message(user.id, agent.id, "hi")
    end
  end

  describe "rename_teammate/4 (#831)" do
    test "sets the current conversation's title, audits the field, broadcasts" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)
      Team.subscribe(user.id)

      assert {:ok, %{title: "Ada (staging)"}} =
               Team.rename_teammate(user.id, ada.id, "  Ada (staging) ", actor: "api")

      assert Repo.reload(conv).title == "Ada (staging)"
      assert [%{name: "Ada (staging)"}] = Team.list_teammates(user.id)
      assert_receive {:team_changed, _}

      assert [ev] =
               Enum.filter(Audit.list_recent_for_user(user.id), &(&1.action == "team.renamed"))

      assert ev.actor == "api"
      assert ev.metadata["fields"] == ["name"]
      assert ev.metadata["cleared"] == false
      refute inspect(ev.metadata) =~ "staging"
    end

    test "blank clears the name back to the agent's; an unchanged name records nothing" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada, title: "Old")

      assert {:ok, %{title: nil}} = Team.rename_teammate(user.id, ada.id, "  ")
      assert [%{name: "Ada"}] = Team.list_teammates(user.id)

      assert {:ok, _} = Team.rename_teammate(user.id, ada.id, nil)

      assert [%{metadata: %{"cleared" => true}}] =
               Enum.filter(Audit.list_recent_for_user(user.id), &(&1.action == "team.renamed"))
    end

    test "the renamed title carries onto a fresh conversation; off the team is not found" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      dead = insert_teammate_conv(user, ada, status: "terminated")
      assert {:ok, _} = Team.rename_teammate(user.id, ada.id, "Renamed")
      assert Repo.reload(dead).title == "Renamed"

      inert_start_child()
      assert {:ok, fresh} = Team.send_message(user.id, ada.id, "hi")
      assert fresh.title == "Renamed"

      loner = insert_agent(user_id: user.id)
      assert {:error, :not_found} = Team.rename_teammate(user.id, loner.id, "x")

      assert {:error, %Ecto.Changeset{}} =
               Team.rename_teammate(user.id, ada.id, String.duplicate("x", 121))
    end
  end

  describe "open_fresh_conversation/3" do
    test "retires the current conversation and opens a new one on the same sandbox" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      prev =
        insert_teammate_conv(user, ada,
          sandbox: sandbox,
          status: "idle",
          title: "Ada (staging)",
          environment_id: env.id,
          vault_id: vault.id,
          runtime_session_id: "sess-old"
        )

      Team.subscribe(user.id)

      assert {:ok, fresh} = Team.open_fresh_conversation(user.id, ada.id, actor: "ui")

      # A new conversation, same computer, fresh session, the teammate's attributes.
      refute fresh.id == prev.id
      assert fresh.sandbox_id == sandbox.id
      assert fresh.status == "idle"
      assert fresh.runtime_session_id == nil
      assert fresh.channel_id == Team.channel()
      assert fresh.title == "Ada (staging)"
      assert fresh.environment_id == env.id
      assert fresh.vault_id == vault.id
      assert fresh.runtime == ada.runtime

      # The old one is past resuming; the sandbox row was not touched.
      assert Repo.reload(prev).status == "terminated"
      assert Repo.reload(sandbox).status == "ready"
      refute Repo.reload(sandbox).terminated_at

      # The roster follows the new one; history lists both, the new one first.
      assert [%{conversation: %{id: id}, name: "Ada (staging)"}] = Team.list_teammates(user.id)
      assert id == fresh.id

      assert [fresh.id, prev.id] ==
               user.id |> Team.list_teammate_conversations(ada.id) |> Enum.map(& &1.id)

      assert_received {:team_changed, _}

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "team.conversation.rotated" in actions
      assert "conversation.created" in actions
    end

    test "a parked computer is kept too, and stays parked" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")
      insert_teammate_conv(user, ada, sandbox: sandbox, status: "idle")

      assert {:ok, fresh} = Team.open_fresh_conversation(user.id, ada.id)
      assert fresh.sandbox_id == sandbox.id
      assert Repo.reload(sandbox).status == "suspended"
    end

    test "releases through the server when one is running; a running turn refuses" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      prev = insert_teammate_conv(user, ada, sandbox: sandbox, status: "running")
      test_pid = self()

      stub(ConversationServer, :release_conversation, fn id, opts ->
        send(test_pid, {:released, id, opts})
        {:error, :busy}
      end)

      assert {:error, :busy} = Team.open_fresh_conversation(user.id, ada.id)
      assert_received {:released, id, opts}
      assert id == prev.id
      assert opts[:audit] == false

      # Nothing was created or recorded.
      assert [prev.id] ==
               user.id |> Team.list_teammate_conversations(ada.id) |> Enum.map(& &1.id)

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      refute "team.conversation.rotated" in actions
    end

    test "a computer still starting cannot change hands" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      for status <- ["pending", "starting"] do
        agent = insert_agent(user_id: user.id)
        sandbox = insert_sandbox(user_id: user.id, status: status)
        insert_teammate_conv(user, agent, sandbox: sandbox, status: "pending")
        assert {:error, :provisioning} = Team.open_fresh_conversation(user.id, agent.id)
      end

      _ = ada
    end

    test "a gone computer means a new one, provisioning now, with the teammate's attributes" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      env = insert_env(user_id: user.id)
      dead_sandbox = insert_sandbox(user_id: user.id, status: "terminated")

      prev =
        insert_teammate_conv(user, ada,
          sandbox: dead_sandbox,
          status: "idle",
          title: "Ada (staging)",
          environment_id: env.id
        )

      inert_start_child()

      assert {:ok, fresh} = Team.open_fresh_conversation(user.id, ada.id)
      refute fresh.id == prev.id
      refute fresh.sandbox_id == dead_sandbox.id
      assert fresh.title == "Ada (staging)"
      assert fresh.environment_id == env.id
      assert Repo.reload(prev).status == "terminated"

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "team.conversation.rotated" in actions
    end

    test "a conversation already past resuming is replaced the same way" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      prev = insert_teammate_conv(user, ada, sandbox: sandbox, status: "terminated")
      inert_start_child()

      assert {:ok, fresh} = Team.open_fresh_conversation(user.id, ada.id)
      refute fresh.id == prev.id
      # Not reused: a terminated conversation's sandbox is not the teammate's
      # computer any more, whatever the row says.
      refute fresh.sandbox_id == sandbox.id
    end

    test "not on the team → :not_found; another tenant's teammate too" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      theirs = insert_agent(user_id: other.id)
      insert_teammate_conv(other, theirs)

      assert {:error, :not_found} = Team.open_fresh_conversation(user.id, agent.id)
      assert {:error, :not_found} = Team.open_fresh_conversation(user.id, theirs.id)
    end
  end

  describe "list_teammate_conversations/2 (#832)" do
    test "every conversation the agent had on the team, newest first; none off the team" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      old = insert_teammate_conv(user, ada, status: "terminated")
      current = insert_teammate_conv(user, ada)
      _unbound = insert_conversation(user_id: user.id, agent: ada)
      _other = insert_teammate_conv(user, insert_agent(user_id: user.id))

      ids = user.id |> Team.list_teammate_conversations(ada.id) |> Enum.map(& &1.id)
      assert ids == [current.id, old.id]
      assert Team.list_teammate_conversations(user.id, insert_agent(user_id: user.id).id) == []
    end
  end

  describe "list_addable_agents/1" do
    test "the user's agents not yet on the team" do
      # No starter agent (ADR 0038): the subject is which of the two agents
      # below is addable, not how many agents the account happens to own.
      user = insert_user_without_agents()
      ada = insert_agent(user_id: user.id, name: "Ada")
      linus = insert_agent(user_id: user.id, name: "Linus")
      insert_teammate_conv(user, ada)

      assert [%{id: id}] = Team.list_addable_agents(user.id)
      assert id == linus.id
    end
  end

  test "channel-bound conversations still list in the ordinary history" do
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id, name: "Ada")
    conv = insert_teammate_conv(user, ada)

    ids = user.id |> Conversations.list_conversations() |> Enum.map(& &1.id)
    assert conv.id in ids
  end
end
