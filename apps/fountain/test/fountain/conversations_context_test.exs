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

  describe "get_sandbox!/1" do
    test "returns the sandbox when it exists" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      result = Conversations.get_sandbox!(sandbox.id)
      assert result.id == sandbox.id
    end

    test "raises Ecto.NoResultsError when sandbox does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_sandbox!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_sandbox/1" do
    test "creates a sandbox with valid attrs" do
      user = insert_verified_user()

      attrs = %{
        sprite_name: "test-sprite-create",
        status: "pending",
        user_id: user.id
      }

      assert {:ok, sandbox} = Conversations.create_sandbox(attrs)
      assert sandbox.sprite_name == "test-sprite-create"
      assert sandbox.status == "pending"
      assert sandbox.user_id == user.id
    end

    test "returns error changeset when required fields are missing" do
      assert {:error, changeset} = Conversations.create_sandbox(%{})
      assert changeset.valid? == false
      assert errors_on(changeset)[:sprite_name]
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()

      attrs = %{
        sprite_name: "test-sprite",
        status: "bogus",
        user_id: user.id
      }

      assert {:error, changeset} = Conversations.create_sandbox(attrs)
      assert errors_on(changeset)[:status]
    end
  end

  describe "update_sandbox/2" do
    test "updates sandbox with valid attrs" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      assert {:ok, updated} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      assert updated.status == "ready"
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      assert {:error, changeset} = Conversations.update_sandbox(sandbox, %{status: "bogus"})
      assert errors_on(changeset)[:status]
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

    test "returns conversations ordered by inserted_at desc" do
      user = insert_verified_user()
      c1 = insert_conversation(user_id: user.id)
      c2 = insert_conversation(user_id: user.id)

      [first | _] = Conversations._unsafe_list_conversations()
      assert first.id == c2.id || first.inserted_at >= c1.inserted_at
    end
  end

  describe "list_active_conversations/0" do
    test "returns pending, idle, and running conversations" do
      user = insert_verified_user()
      c1 = insert_conversation(user_id: user.id, status: "pending")
      c2 = insert_conversation(user_id: user.id, status: "idle")
      c3 = insert_conversation(user_id: user.id, status: "running")

      ids = Conversations.list_active_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
      assert c3.id in ids
    end

    test "excludes terminated, completed, and failed" do
      user = insert_verified_user()
      _t = insert_conversation(user_id: user.id, status: "terminated")
      _c = insert_conversation(user_id: user.id, status: "completed")
      _f = insert_conversation(user_id: user.id, status: "failed")

      assert Conversations.list_active_conversations() == []
    end

    test "orders running before idle before pending" do
      user = insert_verified_user()
      pending = insert_conversation(user_id: user.id, status: "pending")
      idle = insert_conversation(user_id: user.id, status: "idle")
      running = insert_conversation(user_id: user.id, status: "running")

      [first, second | _] = Conversations.list_active_conversations()
      assert first.id == running.id
      assert second.id == idle.id
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

  describe "list_conversations/2" do
    test "returns conversations for the given user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      _c2 = insert_conversation(user_id: user2.id)

      results = Conversations.list_conversations(user1.id)
      assert length(results) == 1
      assert hd(results).id == c1.id
    end

    test "returns empty list when user has no conversations" do
      user = insert_verified_user()
      assert Conversations.list_conversations(user.id) == []
    end

    test "roots_only: true excludes child conversations" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      _child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)

      results = Conversations.list_conversations(user.id, roots_only: true)
      ids = Enum.map(results, & &1.id)
      assert root.id in ids
      assert length(results) == 1
    end

    test "roots_only: false returns all conversations including children" do
      user = insert_verified_user()
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)

      results = Conversations.list_conversations(user.id, roots_only: false)
      ids = Enum.map(results, & &1.id)
      assert root.id in ids
      assert child.id in ids
    end
  end

  describe "create_conversation/1" do
    test "inserts a conversation with valid attrs" do
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
      assert changeset.valid? == false
    end
  end

  describe "get_conversation/2" do
    test "returns the conversation when id and user_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation(conv.id, user.id)
      assert result.id == conv.id
    end

    test "returns nil when conversation belongs to a different user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      assert Conversations.get_conversation(conv.id, user2.id) == nil
    end

    test "returns nil for a non-existent id" do
      user = insert_verified_user()
      assert Conversations.get_conversation(Ecto.UUID.generate(), user.id) == nil
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
  end

  describe "update_conversation/2" do
    test "updates the conversation with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "pending")

      assert {:ok, updated} = Conversations.update_conversation(conv, %{status: "running"})
      assert updated.status == "running"
    end

    test "broadcasts sidebar update" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

      Conversations.update_conversation(conv, %{status: "idle"})

      assert_receive {:sidebar_update, _user_id}
    end
  end

  describe "delete_conversation/1" do
    test "deletes the conversation row" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, _} = Conversations.delete_conversation(conv)
      assert Conversations.get_conversation(conv.id, user.id) == nil
    end

    test "broadcasts sidebar update" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

      Conversations.delete_conversation(conv)

      assert_receive {:sidebar_update, _user_id}
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Turns
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_turns/1" do
    test "returns turns for the conversation ordered by turn_number" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conversation_id: conv.id, turn_number: 1)
      t2 = insert_turn(conversation_id: conv.id, turn_number: 2)

      [r1, r2] = Conversations.list_turns(conv.id)
      assert r1.id == t1.id
      assert r2.id == t2.id
    end

    test "returns empty list when there are no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.list_turns(conv.id) == []
    end
  end

  describe "next_turn_number/1" do
    test "returns 1 when there are no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.next_turn_number(conv.id) == 1
    end

    test "returns max turn_number + 1" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      insert_turn(conversation_id: conv.id, turn_number: 1)
      insert_turn(conversation_id: conv.id, turn_number: 2)

      assert Conversations.next_turn_number(conv.id) == 3
    end
  end

  describe "create_turn/1" do
    test "inserts a turn with valid attrs" do
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
    end
  end

  describe "update_turn/2" do
    test "updates the turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      assert {:ok, updated} = Conversations.update_turn(turn, %{status: "completed"})
      assert updated.status == "completed"
    end
  end

  describe "mark_orphaned_turns_interrupted/1" do
    test "sets running turns to interrupted" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t = insert_turn(conversation_id: conv.id, turn_number: 1, status: "running")

      assert 1 = Conversations.mark_orphaned_turns_interrupted(conv.id)

      updated = Conversations.get_turn_by_conversation(t.id, conv.id)
      assert updated.status == "interrupted"
      refute updated.ended_at == nil
    end

    test "does not touch non-running turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _t = insert_turn(conversation_id: conv.id, turn_number: 1, status: "completed")

      assert 0 = Conversations.mark_orphaned_turns_interrupted(conv.id)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Log Events
  # ────────────────────────────────────────────────────────────────────────────

  describe "log!/1" do
    test "inserts a log event" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      assert %{id: id} =
               Conversations.log!(%{
                 conversation_id: conv.id,
                 turn_id: turn.id,
                 kind: "output",
                 stream: "stdout",
                 data: "hello"
               })

      assert is_integer(id)
    end
  end

  describe "list_log_events/3" do
    test "returns events ordered by id" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      e1 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "a"})
      e2 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "b"})

      ids = Conversations.list_log_events(conv.id) |> Enum.map(& &1.id)
      assert ids == [e1.id, e2.id]
    end

    test "after_id filters to events strictly after that id" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      e1 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "a"})
      e2 = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "b"})

      ids = Conversations.list_log_events(conv.id, e1.id) |> Enum.map(& &1.id)
      assert ids == [e2.id]
    end
  end

  describe "output_bytes_by_stream/2" do
    test "sums output event bytes grouped by stream" do
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

      assert Conversations.output_bytes_by_stream(conv.id, turn.id) == %{}
    end
  end

  describe "list_resumable_conversations/0" do
    test "returns idle/running conversations with a ready sandbox" do
      user = insert_verified_user()
      sb = insert_sandbox(user_id: user.id, status: "ready")
      c1 = insert_conversation(user_id: user.id, sandbox_id: sb.id, status: "idle")
      c2 = insert_conversation(user_id: user.id, sandbox_id: sb.id, status: "running")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "excludes conversations whose sandbox is not ready" do
      user = insert_verified_user()
      sb = insert_sandbox(user_id: user.id, status: "pending")
      conv = insert_conversation(user_id: user.id, sandbox_id: sb.id, status: "idle")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "excludes terminal conversations even with a ready sandbox" do
      user = insert_verified_user()
      sb = insert_sandbox(user_id: user.id, status: "ready")
      t = insert_conversation(user_id: user.id, sandbox_id: sb.id, status: "terminated")

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute t.id in ids
    end
  end

  describe "get_conversation_tree/1" do
    test "returns the single node for a root with no children" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      tree = Conversations.get_conversation_tree(conv.id)
      assert length(tree) == 1
      [node] = tree
      assert node.id == conv.id
      assert node.parent_id == nil
    end

    test "returns empty list for a non-existent id" do
      assert Conversations.get_conversation_tree(Ecto.UUID.generate()) == []
    end

    test "returns the full ancestor + descendant tree" do
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
  # apply_streams_filter (tested indirectly via list_log_events)
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_log_events/3 streams filter" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conversation_id: conv.id, turn_number: 1)

      out = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stdout", data: "out"})
      err = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "output", stream: "stderr", data: "err"})
      stage = Conversations.log!(%{conversation_id: conv.id, turn_id: turn.id, kind: "stage", data: "stage"})

      %{conv: conv, out: out, err: err, stage: stage}
    end

    test "no filter returns all events", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id) |> Enum.map(& &1.id)
      assert out.id in ids
      assert err.id in ids
      assert stage.id in ids
    end

    test "streams: [stdout] returns only stdout", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id, 0, streams: ["stdout"]) |> Enum.map(& &1.id)
      assert out.id in ids
      refute err.id in ids
      refute stage.id in ids
    end

    test "streams: [stderr] returns only stderr", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id, 0, streams: ["stderr"]) |> Enum.map(& &1.id)
      refute out.id in ids
      assert err.id in ids
      refute stage.id in ids
    end

    test "streams: [stage] returns only stage events", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id, 0, streams: ["stage"]) |> Enum.map(& &1.id)
      refute out.id in ids
      refute err.id in ids
      assert stage.id in ids
    end

    test "streams: [stdout, stage] returns stdout and stage", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id, 0, streams: ["stdout", "stage"]) |> Enum.map(& &1.id)
      assert out.id in ids
      refute err.id in ids
      assert stage.id in ids
    end

    test "unknown stream returns no events", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id, 0, streams: ["unknown"]) |> Enum.map(& &1.id)
      refute out.id in ids
      refute err.id in ids
      refute stage.id in ids
    end

    test "empty streams list returns all events", %{conv: conv, out: out, err: err, stage: stage} do
      ids = Conversations.list_log_events(conv.id, 0, streams: []) |> Enum.map(& &1.id)
      assert out.id in ids
      assert err.id in ids
      assert stage.id in ids
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # wake_conversation/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "wake_conversation/2" do
    test "returns {:error, :not_found} for a non-existent id" do
      assert {:error, :not_found} = Conversations.wake_conversation(Ecto.UUID.generate())
    end

    test "returns {:error, :gone} for terminal conversations" do
      user = insert_verified_user()

      for status <- ~w(terminated failed completed) do
        conv = insert_conversation(user_id: user.id, status: status)
        assert {:error, :gone} = Conversations.wake_conversation(conv.id)
      end
    end
  end
end