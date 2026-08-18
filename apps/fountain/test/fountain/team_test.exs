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

  describe "add_teammate/3" do
    test "opens a channel-bound conversation and records the membership" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      inert_start_child()

      assert {:ok, conv} = Team.add_teammate(user.id, agent.id, actor: "ui")
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

  describe "list_addable_agents/1" do
    test "the user's agents not yet on the team" do
      user = insert_verified_user()
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
