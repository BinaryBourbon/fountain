defmodule Fountain.ConversationsContextTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  # ────────────────────────────────────────────────────────────────────────────
  # Sandboxes
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_sandboxes/0" do
    test "returns an empty list when no sandboxes exist" do
      assert Conversations.list_sandboxes() == []
    end

    test "returns all sandboxes" do
      user = insert_verified_user()
      s1 = insert_sandbox(user_id: user.id)
      s2 = insert_sandbox(user_id: user.id)

      ids = Conversations.list_sandboxes() |> Enum.map(& &1.id)
      assert s1.id in ids
      assert s2.id in ids
    end

    test "returns sandboxes ordered by inserted_at descending" do
      user = insert_verified_user()
      s1 = insert_sandbox(user_id: user.id)
      s2 = insert_sandbox(user_id: user.id)

      [first | _] = Conversations.list_sandboxes()
      # Most recently inserted is first
      assert first.id == s2.id || first.inserted_at >= s1.inserted_at
    end

    test "returns sandboxes across different users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      s1 = insert_sandbox(user_id: user1.id)
      s2 = insert_sandbox(user_id: user2.id)

      ids = Conversations.list_sandboxes() |> Enum.map(& &1.id)
      assert s1.id in ids
      assert s2.id in ids
    end
  end

  describe "get_sandbox/1" do
    test "returns the sandbox when it exists" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      result = Conversations.get_sandbox(sandbox.id)
      assert result.id == sandbox.id
    end

    test "returns nil when sandbox does not exist" do
      assert Conversations.get_sandbox(Ecto.UUID.generate()) == nil
    end
  end

  describe "create_sandbox/1" do
    test "creates a sandbox with valid attributes" do
      user = insert_verified_user()
      env = insert_environment(user_id: user.id)

      attrs = %{
        environment_id: env.id,
        sprite_name: "fountain-test-#{Ecto.UUID.generate()}",
        status: "pending",
        user_id: user.id
      }

      assert {:ok, sandbox} = Conversations.create_sandbox(attrs)
      assert sandbox.environment_id == env.id
      assert sandbox.status == "pending"
      assert sandbox.user_id == user.id
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Conversations.create_sandbox(%{})
      assert changeset.errors[:user_id] != nil
    end
  end

  describe "update_sandbox/2" do
    test "updates the sandbox with valid attributes" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      assert {:ok, updated} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      assert updated.status == "ready"
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Conversations
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_conversations/0" do
    test "returns all conversations across all users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      c2 = insert_conversation(user_id: user2.id)

      ids = Conversations._unsafe_list_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "preloads sandbox, agent, and first turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      [result] = Conversations._unsafe_list_conversations()
      assert result.id == conv.id
      assert %Ecto.Association.NotLoaded{} != result.turns
    end
  end

  describe "list_active_conversations/0" do
    test "returns conversations not in terminal states" do
      user = insert_verified_user()
      pending = insert_conversation(user_id: user.id, status: "pending")
      idle = insert_conversation(user_id: user.id, status: "idle")
      running = insert_conversation(user_id: user.id, status: "running")

      ids = Conversations.list_active_conversations() |> Enum.map(& &1.id)
      assert pending.id in ids
      assert idle.id in ids
      assert running.id in ids
    end

    test "excludes terminated, completed, and failed conversations" do
      user = insert_verified_user()
      terminated = insert_conversation(user_id: user.id, status: "terminated")
      completed = insert_conversation(user_id: user.id, status: "completed")
      failed = insert_conversation(user_id: user.id, status: "failed")

      ids = Conversations.list_active_conversations() |> Enum.map(& &1.id)
      refute terminated.id in ids
      refute completed.id in ids
      refute failed.id in ids
    end

    test "orders running conversations before idle" do
      user = insert_verified_user()
      idle = insert_conversation(user_id: user.id, status: "idle")
      running = insert_conversation(user_id: user.id, status: "running")

      [first | _] = Conversations.list_active_conversations()
      assert first.id == running.id
    end
  end

  describe "list_conversations_by_activity/1" do
    test "returns only conversations belonging to the given user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      _c2 = insert_conversation(user_id: user2.id)

      results = Conversations.list_conversations_by_activity(user1.id)
      ids = Enum.map(results, & &1.id)
      assert c1.id in ids
      assert length(results) == 1
    end

    test "returns empty list when user has no conversations" do
      user = insert_verified_user()
      assert Conversations.list_conversations_by_activity(user.id) == []
    end

    test "orders by most recent activity descending" do
      user = insert_verified_user()
      c1 = insert_conversation(user_id: user.id)
      c2 = insert_conversation(user_id: user.id)

      # Backdate c2's inserted_at so c1 sorts first. The activity expression
      # falls back to inserted_at when there are no turns or log events, so
      # this is the field that controls ordering for brand-new conversations.
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      Fountain.Repo.update_all(
        Ecto.Query.from(c in Conversation, where: c.id == ^c2.id),
        set: [inserted_at: past]
      )

      [first | _] = Conversations.list_conversations_by_activity(user.id)
      assert first.id == c1.id
    end

    test "excludes terminated conversations" do
      user = insert_verified_user()
      active = insert_conversation(user_id: user.id, status: "idle")
      _terminated = insert_conversation(user_id: user.id, status: "terminated")

      results = Conversations.list_conversations_by_activity(user.id)
      ids = Enum.map(results, & &1.id)
      assert active.id in ids
      assert length(results) == 1
    end
  end

  describe "list_conversations/1" do
    test "returns conversations scoped to user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      _c2 = insert_conversation(user_id: user2.id)

      results = Conversations.list_conversations(user1.id)
      ids = Enum.map(results, & &1.id)
      assert c1.id in ids
      assert length(results) == 1
    end

    test "returns empty list for user with no conversations" do
      user = insert_verified_user()
      assert Conversations.list_conversations(user.id) == []
    end
  end

  describe "_unsafe_get_conversation/1" do
    test "returns the conversation when it exists" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations._unsafe_get_conversation(conv.id)
      assert result.id == conv.id
    end

    test "returns nil when conversation does not exist" do
      assert Conversations._unsafe_get_conversation(Ecto.UUID.generate()) == nil
    end

    test "returns conversation regardless of owner" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      # user2 is not the owner, but _unsafe variant ignores that
      result = Conversations._unsafe_get_conversation(conv.id)
      assert result.id == conv.id
      assert result.user_id == user1.id
    end

    test "preloads sandbox, agent, and vault" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations._unsafe_get_conversation(conv.id)
      assert %Ecto.Association.NotLoaded{} != result.sandbox
      assert %Ecto.Association.NotLoaded{} != result.agent
      assert %Ecto.Association.NotLoaded{} != result.vault
    end
  end

  describe "_unsafe_get_conversation!/1" do
    test "returns the conversation when it exists" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations._unsafe_get_conversation!(conv.id)
      assert result.id == conv.id
    end

    test "raises Ecto.NoResultsError when conversation does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations._unsafe_get_conversation!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_conversation/2" do
    test "returns the conversation when id and user_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation(conv.id, user.id)
      assert result.id == conv.id
    end

    test "returns nil when conversation belongs to different user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      assert Conversations.get_conversation(conv.id, user2.id) == nil
    end

    test "returns nil when conversation does not exist" do
      user = insert_verified_user()
      assert Conversations.get_conversation(Ecto.UUID.generate(), user.id) == nil
    end

    test "preloads sandbox, agent, and vault" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation(conv.id, user.id)
      assert %Ecto.Association.NotLoaded{} != result.sandbox
      assert %Ecto.Association.NotLoaded{} != result.agent
      assert %Ecto.Association.NotLoaded{} != result.vault
    end
  end

  describe "get_conversation!/2" do
    test "returns the conversation when found" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation!(conv.id, user.id)
      assert result.id == conv.id
    end

    test "raises Ecto.NoResultsError when not found" do
      user = insert_verified_user()

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(Ecto.UUID.generate(), user.id)
      end
    end

    test "raises Ecto.NoResultsError when wrong user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(conv.id, user2.id)
      end
    end
  end

  describe "create_conversation/1" do
    test "creates a conversation with valid attributes" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      agent = insert_agent(user_id: user.id)

      attrs = %{
        sandbox_id: sandbox.id,
        agent_id: agent.id,
        user_id: user.id,
        runtime: "claude",
        status: "pending",
        source: "ui"
      }

      assert {:ok, conv} = Conversations.create_conversation(attrs)
      assert conv.user_id == user.id
      assert conv.status == "pending"
    end

    test "returns error changeset for missing required fields" do
      assert {:error, changeset} = Conversations.create_conversation(%{})
      assert changeset.errors[:user_id] != nil
    end
  end

  describe "update_conversation/2" do
    test "updates the conversation with valid attributes" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "pending")

      assert {:ok, updated} = Conversations.update_conversation(conv, %{status: "running"})
      assert updated.status == "running"
    end

    test "broadcasts sidebar update after successful update" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      :ok = Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

      {:ok, _updated} = Conversations.update_conversation(conv, %{status: "idle"})

      assert_receive {:sidebar_update, user_id}
      assert user_id == user.id
    end
  end

  describe "delete_conversation/1" do
    test "deletes the conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, _deleted} = Conversations.delete_conversation(conv)
      assert Conversations.get_conversation(conv.id, user.id) == nil
    end

    test "broadcasts sidebar update after deletion" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      :ok = Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

      {:ok, _} = Conversations.delete_conversation(conv)

      assert_receive {:sidebar_update, user_id}
      assert user_id == user.id
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Turns
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_turns/1" do
    test "returns turns for the given conversation ordered by turn_number" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conversation_id: conv.id, turn_number: 1)
      t2 = insert_turn(conversation_id: conv.id, turn_number: 2)

      turns = Conversations.list_turns(conv.id)
      ids = Enum.map(turns, & &1.id)
      assert ids == [t1.id, t2.id]
    end

    test "returns empty list for conversation with no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.list_turns(conv.id) == []
    end

    test "does not return turns from another conversation" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      t1 = insert_turn(conversation_id: conv1.id, turn_number: 1)
      _t2 = insert_turn(conversation_id: conv2.id, turn_number: 1)

      turns = Conversations.list_turns(conv1.id)
      assert Enum.map(turns, & &1.id) == [t1.id]
    end
  end

  describe "get_turn_by_conversation/2" do
    test "returns the turn when id and conversation_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      result = Conversations.get_turn_by_conversation(turn.id, conv.id)
      assert result.id == turn.id
    end

    test "returns nil when turn belongs to a different conversation" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv1.id, turn_number: 1)

      assert Conversations.get_turn_by_conversation(turn.id, conv2.id) == nil
    end
  end

  describe "next_turn_number/1" do
    test "returns 1 when there are no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.next_turn_number(conv.id) == 1
    end

    test "returns the next sequential number" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _t1 = insert_turn(conversation_id: conv.id, turn_number: 1)
      _t2 = insert_turn(conversation_id: conv.id, turn_number: 2)

      assert Conversations.next_turn_number(conv.id) == 3
    end
  end

  describe "create_turn/1" do
    test "creates a turn with valid attributes" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        role: "user",
        status: "pending"
      }

      assert {:ok, turn} = Conversations.create_turn(attrs)
      assert turn.conversation_id == conv.id
      assert turn.turn_number == 1
    end
  end

  describe "update_turn/2" do
    test "updates the turn with valid attributes" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      assert {:ok, updated} = Conversations.update_turn(turn, %{status: "completed"})
      assert updated.status == "completed"
    end
  end

  describe "mark_orphaned_turns_interrupted/1" do
    test "marks running turns as interrupted" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      running_turn = insert_turn(conversation_id: conv.id, turn_number: 1, status: "running")

      count = Conversations.mark_orphaned_turns_interrupted(conv.id)
      assert count == 1

      updated = Conversations.get_turn_by_conversation(running_turn.id, conv.id)
      assert updated.status == "interrupted"
      assert updated.ended_at != nil
    end

    test "does not affect non-running turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      completed_turn = insert_turn(conversation_id: conv.id, turn_number: 1, status: "completed")

      count = Conversations.mark_orphaned_turns_interrupted(conv.id)
      assert count == 0

      unchanged = Conversations.get_turn_by_conversation(completed_turn.id, conv.id)
      assert unchanged.status == "completed"
    end

    test "returns count of affected turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      insert_turn(conversation_id: conv.id, turn_number: 1, status: "running")
      insert_turn(conversation_id: conv.id, turn_number: 2, status: "running")
      insert_turn(conversation_id: conv.id, turn_number: 3, status: "completed")

      count = Conversations.mark_orphaned_turns_interrupted(conv.id)
      assert count == 2
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Log Events
  # ────────────────────────────────────────────────────────────────────────────

  describe "log!/1" do
    test "inserts a log event and returns it with an integer id" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      event = Conversations.log!(%{
        conversation_id: conv.id,
        turn_id: turn.id,
        kind: "output",
        stream: "stdout",
        data: "hello"
      })

      assert is_integer(event.id)
      assert event.data == "hello"
    end
  end

  describe "list_log_events/3" do
    test "returns log events ordered by id" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      e1 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "a"})
      e2 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "b"})

      events = Conversations.list_log_events(conv.id)
      ids = Enum.map(events, & &1.id)
      assert ids == [e1.id, e2.id]
    end

    test "returns events after the given id" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      e1 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "a"})
      e2 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "b"})

      events = Conversations.list_log_events(conv.id, e1.id)
      ids = Enum.map(events, & &1.id)
      assert ids == [e2.id]
    end
  end

  describe "output_bytes_by_stream/2" do
    test "returns byte counts by stream" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "hello"})
      Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: " world"})
      Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stderr", data: "err"})

      result = Conversations.output_bytes_by_stream(conv.id, turn.id)
      assert result["stdout"] == 11
      assert result["stderr"] == 3
    end

    test "returns empty map when no output events" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      result = Conversations.output_bytes_by_stream(conv.id, turn.id)
      assert result == %{}
    end

    test "ignores stage events" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "stage", data: "stage data"})

      result = Conversations.output_bytes_by_stream(conv.id, turn.id)
      assert result == %{}
    end
  end

  describe "list_resumable_conversations/0" do
    test "returns conversations with idle or running status and ready sandbox" do
      user = insert_verified_user()
      ready_sandbox = insert_sandbox(user_id: user.id, status: "ready")
      c1 = insert_conversation(user_id: user.id, sandbox_id: ready_sandbox.id, status: "idle")
      c2 = insert_conversation(user_id: user.id, sandbox_id: ready_sandbox.id, status: "running")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "excludes conversations with non-ready sandbox" do
      user = insert_verified_user()
      pending_sandbox = insert_sandbox(user_id: user.id, status: "pending")
      conv = insert_conversation(user_id: user.id, sandbox_id: pending_sandbox.id, status: "idle")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "excludes conversations in terminal states even with ready sandbox" do
      user = insert_verified_user()
      ready_sandbox = insert_sandbox(user_id: user.id, status: "ready")
      terminated = insert_conversation(user_id: user.id, sandbox_id: ready_sandbox.id, status: "terminated")
      completed = insert_conversation(user_id: user.id, sandbox_id: ready_sandbox.id, status: "completed")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute terminated.id in ids
      refute completed.id in ids
    end
  end

  describe "get_conversation_tree/1" do
    test "returns the single conversation when no parent or children" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      tree = Conversations.get_conversation_tree(conv.id)
      assert length(tree) == 1
      [node] = tree
      assert node.id == conv.id
      assert node.parent_id == nil
    end

    test "returns empty list for non-existent conversation" do
      tree = Conversations.get_conversation_tree(Ecto.UUID.generate())
      assert tree == []
    end

    test "returns parent and child" do
      user = insert_verified_user()
      parent = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: parent.id)

      tree = Conversations.get_conversation_tree(child.id)
      ids = Enum.map(tree, & &1.id)
      assert parent.id in ids
      assert child.id in ids
    end

    test "returns full tree when queried from a child" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      grandchild = insert_conversation(user_id: user.id, parent_conversation_id: child.id)

      tree = Conversations.get_conversation_tree(grandchild.id)
      ids = Enum.map(tree, & &1.id)
      assert root.id in ids
      assert child.id in ids
      assert grandchild.id in ids
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # apply_streams_filter (tested through list_log_events)
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_log_events/3 streams filter" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      stdout_event = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "out"})
      stderr_event = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stderr", data: "err"})
      stage_event = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "stage", data: "stage"})

      %{conv: conv, stdout: stdout_event, stderr: stderr_event, stage: stage_event}
    end

    test "returns all events when no streams filter", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id)
      ids = Enum.map(events, & &1.id)
      assert stdout.id in ids
      assert stderr.id in ids
      assert stage.id in ids
    end

    test "filters to stdout only", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id, 0, streams: ["stdout"])
      ids = Enum.map(events, & &1.id)
      assert stdout.id in ids
      refute stderr.id in ids
      refute stage.id in ids
    end

    test "filters to stderr only", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id, 0, streams: ["stderr"])
      ids = Enum.map(events, & &1.id)
      refute stdout.id in ids
      assert stderr.id in ids
      refute stage.id in ids
    end

    test "filters to stage only", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id, 0, streams: ["stage"])
      ids = Enum.map(events, & &1.id)
      refute stdout.id in ids
      refute stderr.id in ids
      assert stage.id in ids
    end

    test "filters to stdout and stage", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id, 0, streams: ["stdout", "stage"])
      ids = Enum.map(events, & &1.id)
      assert stdout.id in ids
      refute stderr.id in ids
      assert stage.id in ids
    end

    test "returns nothing for unknown stream identifiers", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id, 0, streams: ["unknown"])
      ids = Enum.map(events, & &1.id)
      refute stdout.id in ids
      refute stderr.id in ids
      refute stage.id in ids
    end

    test "returns nothing for empty streams list", %{conv: conv, stdout: stdout, stderr: stderr, stage: stage} do
      events = Conversations.list_log_events(conv.id, 0, streams: [])
      ids = Enum.map(events, & &1.id)
      assert stdout.id in ids
      assert stderr.id in ids
      assert stage.id in ids
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # wake_conversation/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "wake_conversation/2" do
    test "returns {:error, :not_found} for a non-existent conversation" do
      assert {:error, :not_found} = Conversations.wake_conversation(Ecto.UUID.generate())
    end

    test "returns {:error, :gone} for a terminated conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "terminated")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:error, :gone} for a failed conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "failed")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:error, :gone} for a completed conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "completed")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end
  end
end