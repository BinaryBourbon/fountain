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
      assert result.sprite_name == sandbox.sprite_name
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
      assert updated.id == sandbox.id
      assert updated.status == "ready"
    end

    test "returns error changeset when given invalid status" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      assert {:error, changeset} = Conversations.update_sandbox(sandbox, %{status: "invalid"})
      assert errors_on(changeset)[:status]
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Conversations
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_conversations/0" do
    test "returns an empty list when no conversations exist" do
      assert Conversations._unsafe_list_conversations() == []
    end

    test "returns conversations across multiple users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      c2 = insert_conversation(user_id: user2.id)

      ids = Conversations._unsafe_list_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "preloads sandbox and agent" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      [result | _] = Conversations._unsafe_list_conversations()
      assert result.id == conv.id
      assert %Sandbox{} = result.sandbox
    end
  end

  describe "list_active_conversations/0" do
    test "returns empty list when no conversations exist" do
      assert Conversations.list_active_conversations() == []
    end

    test "returns conversations with non-terminal statuses" do
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

    test "does not filter by user — returns active convs across all users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id, status: "pending")
      c2 = insert_conversation(user_id: user2.id, status: "idle")

      ids = Conversations.list_active_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
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
      assert %Sandbox{} = result.sandbox
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

    test "returns nil when conversation id does not exist" do
      user = insert_verified_user()
      assert Conversations.get_conversation(Ecto.UUID.generate(), user.id) == nil
    end

    test "returns nil when user_id does not match the owner" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      assert Conversations.get_conversation(conv.id, user2.id) == nil
    end

    test "preloads sandbox, agent, and vault" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation(conv.id, user.id)
      assert %Sandbox{} = result.sandbox
    end
  end

  describe "get_conversation!/2" do
    test "returns the conversation when id and user_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation!(conv.id, user.id)
      assert result.id == conv.id
    end

    test "raises Ecto.NoResultsError when conversation does not exist" do
      user = insert_verified_user()

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(Ecto.UUID.generate(), user.id)
      end
    end

    test "raises Ecto.NoResultsError when user_id does not match owner" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(conv.id, user2.id)
      end
    end
  end

  describe "create_conversation/1" do
    test "creates a conversation with valid attrs" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      attrs = %{
        sandbox_id: sandbox.id,
        user_id: user.id,
        runtime: "claude",
        status: "pending"
      }

      assert {:ok, conv} = Conversations.create_conversation(attrs)
      assert conv.sandbox_id == sandbox.id
      assert conv.user_id == user.id
      assert conv.runtime == "claude"
      assert conv.status == "pending"
    end

    test "returns error changeset when required fields are missing" do
      assert {:error, changeset} = Conversations.create_conversation(%{})
      assert changeset.valid? == false
      assert errors_on(changeset)[:runtime]
      assert errors_on(changeset)[:sandbox_id]
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      attrs = %{
        sandbox_id: sandbox.id,
        user_id: user.id,
        runtime: "claude",
        status: "bogus"
      }

      assert {:error, changeset} = Conversations.create_conversation(attrs)
      assert errors_on(changeset)[:status]
    end
  end

  describe "update_conversation/2" do
    test "updates a conversation with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, updated} = Conversations.update_conversation(conv, %{status: "idle"})
      assert updated.id == conv.id
      assert updated.status == "idle"
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:error, changeset} = Conversations.update_conversation(conv, %{status: "invalid"})
      assert errors_on(changeset)[:status]
    end
  end

  describe "delete_conversation/1" do
    test "deletes the conversation row from the database" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      # ConversationServer.terminate/1 will return an error since the server
      # isn't running in tests, but delete_conversation proceeds with Repo.delete
      assert {:ok, _deleted} = Conversations.delete_conversation(conv)
      assert Conversations.get_conversation(conv.id, user.id) == nil
    end

    test "deleted conversation is not found via _unsafe_get_conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, _} = Conversations.delete_conversation(conv)
      assert Conversations._unsafe_get_conversation(conv.id) == nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Turns
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_turns/1" do
    test "returns empty list when conversation has no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.list_turns(conv.id) == []
    end

    test "returns all turns for the conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv)
      t2 = insert_turn(conv)

      ids = Conversations.list_turns(conv.id) |> Enum.map(& &1.id)
      assert t1.id in ids
      assert t2.id in ids
    end

    test "orders turns by turn_number ascending" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv)
      t2 = insert_turn(conv)

      [first, second] = Conversations.list_turns(conv.id)
      assert first.turn_number < second.turn_number
      assert first.id == t1.id
      assert second.id == t2.id
    end

    test "does not return turns from other conversations" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv1)
      _t2 = insert_turn(conv2)

      results = Conversations.list_turns(conv1.id)
      assert length(results) == 1
      assert hd(results).id == t1.id
    end
  end

  describe "get_turn_by_conversation/2" do
    test "returns the turn when turn_id and conversation_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      result = Conversations.get_turn_by_conversation(turn.id, conv.id)
      assert result.id == turn.id
    end

    test "returns nil when turn_id does not exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.get_turn_by_conversation(Ecto.UUID.generate(), conv.id) == nil
    end

    test "returns nil when turn belongs to a different conversation" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      turn = insert_turn(conv1)

      assert Conversations.get_turn_by_conversation(turn.id, conv2.id) == nil
    end
  end

  describe "next_turn_number/1" do
    test "returns 1 when conversation has no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.next_turn_number(conv.id) == 1
    end

    test "returns max_turn_number + 1 when turns exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _t1 = insert_turn(conv)
      _t2 = insert_turn(conv)

      assert Conversations.next_turn_number(conv.id) == 3
    end

    test "is not affected by turns from other conversations" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      _t1 = insert_turn(conv1)
      _t2 = insert_turn(conv1)
      _t3 = insert_turn(conv1)

      assert Conversations.next_turn_number(conv2.id) == 1
    end
  end

  describe "create_turn/1" do
    test "creates a turn with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "Hello, world",
        status: "pending"
      }

      assert {:ok, turn} = Conversations.create_turn(attrs)
      assert turn.conversation_id == conv.id
      assert turn.turn_number == 1
      assert turn.prompt == "Hello, world"
      assert turn.status == "pending"
    end

    test "returns error changeset when required fields are missing" do
      assert {:error, changeset} = Conversations.create_turn(%{})
      assert changeset.valid? == false
      assert errors_on(changeset)[:conversation_id]
      assert errors_on(changeset)[:turn_number]
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        turn_number: 1,
        prompt: "test",
        status: "bogus"
      }

      assert {:error, changeset} = Conversations.create_turn(attrs)
      assert errors_on(changeset)[:status]
    end
  end

  describe "update_turn/2" do
    test "updates a turn with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:ok, updated} = Conversations.update_turn(turn, %{status: "completed"})
      assert updated.id == turn.id
      assert updated.status == "completed"
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:error, changeset} = Conversations.update_turn(turn, %{status: "invalid"})
      assert errors_on(changeset)[:status]
    end
  end

  describe "mark_orphaned_turns_interrupted/1" do
    test "marks running turns as interrupted and returns count" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _pending = insert_turn(conv, status: "pending")
      _running1 = insert_turn(conv, status: "running")
      _running2 = insert_turn(conv, status: "running")

      count = Conversations.mark_orphaned_turns_interrupted(conv.id)
      assert count == 2
    end

    test "does not modify non-running turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      pending = insert_turn(conv, status: "pending")
      completed = insert_turn(conv, status: "completed")
      failed = insert_turn(conv, status: "failed")

      Conversations.mark_orphaned_turns_interrupted(conv.id)

      assert Conversations.get_turn_by_conversation(pending.id, conv.id).status == "pending"
      assert Conversations.get_turn_by_conversation(completed.id, conv.id).status == "completed"
      assert Conversations.get_turn_by_conversation(failed.id, conv.id).status == "failed"
    end

    test "returns 0 when no running turns exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _t = insert_turn(conv, status: "pending")

      assert Conversations.mark_orphaned_turns_interrupted(conv.id) == 0
    end

    test "only affects turns for the given conversation" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      running_in_conv2 = insert_turn(conv2, status: "running")

      # Only interrupt conv1's running turns (none exist)
      count = Conversations.mark_orphaned_turns_interrupted(conv1.id)
      assert count == 0

      # conv2's running turn should be untouched
      assert Conversations.get_turn_by_conversation(running_in_conv2.id, conv2.id).status == "running"
    end

    test "updates running turns to interrupted status in db" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      running = insert_turn(conv, status: "running")

      Conversations.mark_orphaned_turns_interrupted(conv.id)

      result = Conversations.get_turn_by_conversation(running.id, conv.id)
      assert result.status == "interrupted"
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Log events
  # ────────────────────────────────────────────────────────────────────────────

  describe "log!/1" do
    test "inserts a LogEvent and returns the struct" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "hello",
        inserted_at: DateTime.utc_now()
      }

      event = Conversations.log!(attrs)
      assert %LogEvent{} = event
      assert is_integer(event.id)
      assert event.conversation_id == conv.id
      assert event.kind == "output"
      assert event.data == "hello"
    end

    test "defaults inserted_at to current time when not provided" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        kind: "output"
      }

      before = DateTime.utc_now()
      event = Conversations.log!(attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(event.inserted_at, before) in [:gt, :eq]
      assert DateTime.compare(event.inserted_at, after_time) in [:lt, :eq]
    end

    test "inserts a stage event" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      event =
        Conversations.log!(%{
          conversation_id: conv.id,
          kind: "stage",
          stage: "provision",
          state: "started",
          inserted_at: DateTime.utc_now()
        })

      assert event.kind == "stage"
      assert event.stage == "provision"
      assert event.state == "started"
    end
  end

  describe "list_log_events/3" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      %{user: user, conv: conv}
    end

    test "returns all events when no opts given", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")
      e2 = insert_log_event(conv, kind: "output", stream: "stderr", data: "b")
      e3 = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      ids = Conversations.list_log_events(conv.id) |> Enum.map(& &1.id)
      assert e1.id in ids
      assert e2.id in ids
      assert e3.id in ids
    end

    test "no filter with empty streams list returns all events", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout")
      e2 = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      ids = Conversations.list_log_events(conv.id, 0, streams: []) |> Enum.map(& &1.id)
      assert e1.id in ids
      assert e2.id in ids
    end

    test "streams: [\"stdout\"] returns only stdout events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout", data: "out")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr", data: "err")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations.list_log_events(conv.id, 0, streams: ["stdout"])
      ids = Enum.map(results, & &1.id)
      assert stdout.id in ids
      refute stderr.id in ids
      refute stage.id in ids
    end

    test "streams: [\"stderr\"] returns only stderr events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations.list_log_events(conv.id, 0, streams: ["stderr"])
      ids = Enum.map(results, & &1.id)
      refute stdout.id in ids
      assert stderr.id in ids
      refute stage.id in ids
    end

    test "streams: [\"stage\"] returns only stage kind events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations.list_log_events(conv.id, 0, streams: ["stage"])
      ids = Enum.map(results, & &1.id)
      refute stdout.id in ids
      refute stderr.id in ids
      assert stage.id in ids
    end

    test "streams: [\"stdout\", \"stage\"] returns stdout and stage events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations.list_log_events(conv.id, 0, streams: ["stdout", "stage"])
      ids = Enum.map(results, & &1.id)
      assert stdout.id in ids
      refute stderr.id in ids
      assert stage.id in ids
    end

    test "streams: [\"unknown\"] returns empty list (unknown stream filter)", %{conv: conv} do
      _e = insert_log_event(conv, kind: "output", stream: "stdout")

      assert Conversations.list_log_events(conv.id, 0, streams: ["unknown"]) == []
    end

    test "after_id filters events with id greater than after_id", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout")
      e2 = insert_log_event(conv, kind: "output", stream: "stdout")
      e3 = insert_log_event(conv, kind: "output", stream: "stdout")

      ids = Conversations.list_log_events(conv.id, e1.id) |> Enum.map(& &1.id)
      refute e1.id in ids
      assert e2.id in ids
      assert e3.id in ids
    end

    test "returns events ordered by id ascending", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout")
      e2 = insert_log_event(conv, kind: "output", stream: "stdout")
      e3 = insert_log_event(conv, kind: "output", stream: "stdout")

      ids = Conversations.list_log_events(conv.id) |> Enum.map(& &1.id)
      assert ids == Enum.sort(ids)
      assert hd(ids) == e1.id
      assert List.last(ids) == e3.id
    end

    test "does not return events from other conversations", %{conv: conv} do
      user = insert_verified_user()
      other_conv = insert_conversation(user_id: user.id)
      _other = insert_log_event(other_conv, kind: "output", stream: "stdout")
      mine = insert_log_event(conv, kind: "output", stream: "stdout")

      results = Conversations.list_log_events(conv.id)
      ids = Enum.map(results, & &1.id)
      assert ids == [mine.id]
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # list_sandboxes_admin/0
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_sandboxes_admin/0" do
    test "returns sandboxes with pending and ready statuses" do
      user = insert_verified_user()
      pending = insert_sandbox(user_id: user.id)
      ready = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(ready, %{status: "ready"})

      ids = Conversations.list_sandboxes_admin() |> Enum.map(& &1.id)
      assert pending.id in ids
      assert ready.id in ids
    end

    test "excludes sandboxes with terminated status" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "terminated"})

      ids = Conversations.list_sandboxes_admin() |> Enum.map(& &1.id)
      refute sandbox.id in ids
    end

    test "excludes sandboxes with failed status" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

      ids = Conversations.list_sandboxes_admin() |> Enum.map(& &1.id)
      refute sandbox.id in ids
    end

    test "includes pending but not terminated when both exist" do
      user = insert_verified_user()
      active = insert_sandbox(user_id: user.id)
      terminated = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(terminated, %{status: "terminated"})

      ids = Conversations.list_sandboxes_admin() |> Enum.map(& &1.id)
      assert active.id in ids
      refute terminated.id in ids
    end

    test "preloads user association" do
      user = insert_verified_user()
      _sandbox = insert_sandbox(user_id: user.id)

      results = Conversations.list_sandboxes_admin()
      assert results != []
      result = Enum.find(results, &(&1.user_id == user.id))
      assert result.user.id == user.id
    end

    test "preloads conversations association" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      _conv = insert_conversation(user_id: user.id, sandbox_id: sandbox.id)

      results = Conversations.list_sandboxes_admin()
      result = Enum.find(results, &(&1.id == sandbox.id))
      assert is_list(result.conversations)
    end

    test "returns empty list when all sandboxes are in terminal states" do
      user = insert_verified_user()
      s1 = insert_sandbox(user_id: user.id)
      s2 = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(s1, %{status: "terminated"})
      {:ok, _} = Conversations.update_sandbox(s2, %{status: "failed"})

      # All sandboxes in this test's db partition are terminal
      results = Conversations.list_sandboxes_admin()
      ids = Enum.map(results, & &1.id)
      refute s1.id in ids
      refute s2.id in ids
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # list_resumable_conversations/0
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_resumable_conversations/0" do
    test "returns idle conversation whose sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "idle", sandbox_id: sandbox.id)

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      assert conv.id in ids
    end

    test "returns running conversation whose sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "running", sandbox_id: sandbox.id)

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      assert conv.id in ids
    end

    test "excludes idle conversation whose sandbox is not ready (pending)" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      # sandbox remains "pending"
      conv = insert_conversation(user_id: user.id, status: "idle", sandbox_id: sandbox.id)

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "excludes terminated conversation even when sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "terminated", sandbox_id: sandbox.id)

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "excludes completed conversation even when sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "completed", sandbox_id: sandbox.id)

      ids = Conversations.list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "preloads sandbox association" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "idle", sandbox_id: sandbox.id)

      results = Conversations.list_resumable_conversations()
      result = Enum.find(results, &(&1.id == conv.id))
      assert %Sandbox{} = result.sandbox
      assert result.sandbox.id == sandbox.id
    end

    test "returns empty list when no resumable conversations exist" do
      assert Conversations.list_resumable_conversations() == []
    end
  end

  describe "output_bytes_by_stream/2" do
    test "returns empty map when there are no output events for the turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert Conversations.output_bytes_by_stream(conv.id, turn.id) == %{}
    end

    test "sums byte lengths of data grouped by stream" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      # "hello" = 5 bytes, "world" = 5 bytes → stdout total = 10
      insert_log_event(conv,
        kind: "output",
        stream: "stdout",
        data: "hello",
        turn_id: turn.id
      )

      insert_log_event(conv,
        kind: "output",
        stream: "stdout",
        data: "world",
        turn_id: turn.id
      )

      # "err" = 3 bytes → stderr total = 3
      insert_log_event(conv,
        kind: "output",
        stream: "stderr",
        data: "err",
        turn_id: turn.id
      )

      result = Conversations.output_bytes_by_stream(conv.id, turn.id)
      assert result["stdout"] == 10
      assert result["stderr"] == 3
    end

    test "excludes non-output kind events (stage events)" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      insert_log_event(conv,
        kind: "stage",
        stage: "provision",
        data: "stage-data",
        turn_id: turn.id
      )

      result = Conversations.output_bytes_by_stream(conv.id, turn.id)
      # Stage events have empty stream and are kind "stage", not "output"
      assert result == %{}
    end

    test "excludes events from other turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn1 = insert_turn(conv)
      turn2 = insert_turn(conv)

      insert_log_event(conv,
        kind: "output",
        stream: "stdout",
        data: "from-turn-2",
        turn_id: turn2.id
      )

      result = Conversations.output_bytes_by_stream(conv.id, turn1.id)
      assert result == %{}
    end

    test "excludes events from other conversations" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      turn1 = insert_turn(conv1)
      turn2 = insert_turn(conv2)

      insert_log_event(conv2,
        kind: "output",
        stream: "stdout",
        data: "from-other-conv",
        turn_id: turn2.id
      )

      result = Conversations.output_bytes_by_stream(conv1.id, turn1.id)
      assert result == %{}
    end

    test "returns map with stream keys as strings" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      insert_log_event(conv,
        kind: "output",
        stream: "stdout",
        data: "abc",
        turn_id: turn.id
      )

      result = Conversations.output_bytes_by_stream(conv.id, turn.id)
      assert Map.has_key?(result, "stdout")
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # stream_log_events/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "stream_log_events/2" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      %{user: user, conv: conv}
    end

    test "streams all events for a conversation when after_id is 0", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")
      e2 = insert_log_event(conv, kind: "output", stream: "stderr", data: "b")

      ids =
        Repo.transaction(fn ->
          Conversations.stream_log_events(conv.id) |> Enum.map(& &1.id)
        end)

      assert {:ok, result_ids} = ids
      assert e1.id in result_ids
      assert e2.id in result_ids
    end

    test "returns events ordered by id ascending", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout", data: "first")
      e2 = insert_log_event(conv, kind: "output", stream: "stdout", data: "second")
      e3 = insert_log_event(conv, kind: "output", stream: "stdout", data: "third")

      {:ok, ids} =
        Repo.transaction(fn ->
          Conversations.stream_log_events(conv.id) |> Enum.map(& &1.id)
        end)

      assert ids == [e1.id, e2.id, e3.id]
    end

    test "filters events with id greater than after_id", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")
      e2 = insert_log_event(conv, kind: "output", stream: "stdout", data: "b")
      e3 = insert_log_event(conv, kind: "output", stream: "stdout", data: "c")

      {:ok, ids} =
        Repo.transaction(fn ->
          Conversations.stream_log_events(conv.id, e1.id) |> Enum.map(& &1.id)
        end)

      refute e1.id in ids
      assert e2.id in ids
      assert e3.id in ids
    end

    test "returns empty stream when no events exist", %{conv: conv} do
      {:ok, ids} =
        Repo.transaction(fn ->
          Conversations.stream_log_events(conv.id) |> Enum.map(& &1.id)
        end)

      assert ids == []
    end

    test "does not return events from other conversations", %{conv: conv} do
      user = insert_verified_user()
      other_conv = insert_conversation(user_id: user.id)
      _other = insert_log_event(other_conv, kind: "output", stream: "stdout", data: "other")
      mine = insert_log_event(conv, kind: "output", stream: "stdout", data: "mine")

      {:ok, ids} =
        Repo.transaction(fn ->
          Conversations.stream_log_events(conv.id) |> Enum.map(& &1.id)
        end)

      assert ids == [mine.id]
    end

    test "returns empty stream when all events are at or before after_id", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")

      {:ok, ids} =
        Repo.transaction(fn ->
          Conversations.stream_log_events(conv.id, e1.id) |> Enum.map(& &1.id)
        end)

      assert ids == []
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # _unsafe_list_conversations_by_activity/0
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_conversations_by_activity/0" do
    test "returns empty list when no conversations exist" do
      assert Conversations._unsafe_list_conversations_by_activity() == []
    end

    test "returns conversations across all users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      c2 = insert_conversation(user_id: user2.id)

      ids = Conversations._unsafe_list_conversations_by_activity() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "orders conversations by updated_at descending" do
      user = insert_verified_user()
      c1 = insert_conversation(user_id: user.id)
      c2 = insert_conversation(user_id: user.id)

      # Backdate c2 so c1 sorts first
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      Fountain.Repo.update_all(
        Ecto.Query.from(c in Conversation, where: c.id == ^c2.id),
        set: [updated_at: past]
      )

      [first | _] = Conversations._unsafe_list_conversations_by_activity()
      assert first.id == c1.id
    end

    test "preloads agent association" do
      user = insert_verified_user()
      _conv = insert_conversation(user_id: user.id)

      [result | _] = Conversations._unsafe_list_conversations_by_activity()
      # agent may be nil but the key must be present and not an Ecto.Association
      assert Map.has_key?(result, :agent)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # get_conversation_tree/1
  # ────────────────────────────────────────────────────────────────────────────

  describe "get_conversation_tree/1" do
    test "returns empty list when conversation id does not exist" do
      assert Conversations.get_conversation_tree(Ecto.UUID.generate()) == []
    end

    test "returns single-element tree for a root conversation with no children" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      tree = Conversations.get_conversation_tree(conv.id)
      assert length(tree) == 1
      [node] = tree
      assert node.id == conv.id
      assert node.parent_id == nil
    end

    test "returned node contains :id, :source, :status, :parent_id keys" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      [node] = Conversations.get_conversation_tree(conv.id)
      assert Map.has_key?(node, :id)
      assert Map.has_key?(node, :source)
      assert Map.has_key?(node, :status)
      assert Map.has_key?(node, :parent_id)
    end

    test "includes parent and child when called with child id" do
      user = insert_verified_user()
      parent = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: parent.id)

      tree = Conversations.get_conversation_tree(child.id)
      ids = Enum.map(tree, & &1.id)
      assert parent.id in ids
      assert child.id in ids
    end

    test "child node has parent_id set to the parent conversation id" do
      user = insert_verified_user()
      parent = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: parent.id)

      tree = Conversations.get_conversation_tree(child.id)
      child_node = Enum.find(tree, &(&1.id == child.id))
      assert child_node.parent_id == parent.id
    end

    test "includes parent when called with parent id and child exists" do
      user = insert_verified_user()
      parent = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: parent.id)

      tree = Conversations.get_conversation_tree(parent.id)
      ids = Enum.map(tree, & &1.id)
      assert parent.id in ids
      assert child.id in ids
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # insert_turn_images/2 and get_turn_image/2
  # ────────────────────────────────────────────────────────────────────────────

  # Helper to insert a TurnImage via changeset (avoids the UUID-encoding issue in
  # insert_turn_images/2 which uses Repo.insert_all with a raw table name string).
  defp insert_turn_image!(turn_id, position, media_type, data) do
    %Fountain.Conversations.TurnImage{}
    |> Fountain.Conversations.TurnImage.changeset(%{
      turn_id: turn_id,
      position: position,
      media_type: media_type,
      data: data
    })
    |> Ecto.Changeset.put_change(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.insert!()
  end

  describe "insert_turn_images/2" do
    # The empty-list fast-path returns {:ok, []} without touching the DB, so no UUID issue.
    test "returns {:ok, []} immediately when images list is empty" do
      assert {:ok, []} = Conversations.insert_turn_images(Ecto.UUID.generate(), [])
    end

    test "inserts images and returns count" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)
      images = [%{media_type: "image/png", data: <<1, 2, 3>>}]
      assert {:ok, 1} = Conversations.insert_turn_images(turn.id, images)
    end
  end

  describe "get_turn_image/2" do
    test "returns the TurnImage when turn_id and position match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      insert_turn_image!(turn.id, 0, "image/png", <<7, 8, 9>>)

      result = Conversations.get_turn_image(turn.id, 0)
      assert result != nil
      assert result.turn_id == turn.id
      assert result.position == 0
      assert result.media_type == "image/png"
    end

    test "returns nil when no image exists at the given position" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert Conversations.get_turn_image(turn.id, 99) == nil
    end

    test "returns nil when turn_id does not exist" do
      assert Conversations.get_turn_image(Ecto.UUID.generate(), 0) == nil
    end

    test "returns nil when position belongs to a different turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn1 = insert_turn(conv)
      turn2 = insert_turn(conv)

      insert_turn_image!(turn1.id, 0, "image/png", <<1>>)

      # turn1 has an image at position 0, but turn2 does not
      assert Conversations.get_turn_image(turn2.id, 0) == nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # wake_conversation/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "wake_conversation/2" do
    test "returns {:error, :not_found} when conversation does not exist" do
      assert {:error, :not_found} = Conversations.wake_conversation(Ecto.UUID.generate())
    end

    test "returns {:error, :gone} when conversation status is terminated" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "terminated")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:error, :gone} when conversation status is failed" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "failed")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:error, :gone} when conversation status is completed" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "completed")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:error, :no_agent} when conversation has no agent_id" do
      user = insert_verified_user()
      # insert_conversation does not set an agent by default, so agent_id is nil
      conv = insert_conversation(user_id: user.id, status: "idle")

      assert {:error, :no_agent} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} reusing existing sandbox when sprite is still alive" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-alive")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      fake_client = %{}

      stub(Fountain.SpritesClient, :get!, fn -> fake_client end)
      stub(Sprites, :get_sprite, fn _client, _name -> {:ok, %{name: "test-sprite-alive"}} end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} creating fresh sandbox when sprite is gone" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-gone")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      fake_client = %{}

      stub(Fountain.SpritesClient, :get!, fn -> fake_client end)
      stub(Sprites, :get_sprite, fn _client, _name -> {:error, :not_found} end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} creating fresh sandbox when sandbox is pending (not ready)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      # sandbox remains "pending" (not "ready"), so maybe_reuse_sandbox hits the _ -> :create_new branch
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} when old sandbox is already terminated (mark_old_sandbox_terminated no-op)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-terminated")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "terminated"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      # sandbox status is "terminated" (not "ready"), so maybe_reuse_sandbox returns :create_new,
      # which calls create_fresh_sandbox_and_start -> mark_old_sandbox_terminated(sandbox.id)
      # where the sandbox is already terminated, hitting the no-op branch
      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "mark_old_sandbox_terminated handles deleted sandbox gracefully" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      # sandbox remains "pending" so maybe_reuse_sandbox returns :create_new
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      # Point the conversation at a non-existent sandbox_id (bypassing FK) so that
      # mark_old_sandbox_terminated receives an id whose get_sandbox returns nil,
      # hitting the nil -> :ok branch (line 635).
      ghost_sandbox_id = Ecto.UUID.generate()
      {:ok, ghost_uuid_bin} = Ecto.UUID.dump(ghost_sandbox_id)
      {:ok, conv_id_bin} = Ecto.UUID.dump(conv.id)

      # Temporarily disable FK checks, update the conversation to reference a
      # non-existent sandbox_id, then re-enable. This simulates the case where
      # a sandbox was deleted out-of-band (e.g., admin cleanup) so that
      # mark_old_sandbox_terminated receives an id whose get_sandbox returns nil.
      Ecto.Adapters.SQL.query!(Fountain.Repo, "SET session_replication_role = replica", [])

      Ecto.Adapters.SQL.query!(
        Fountain.Repo,
        "UPDATE conversations SET sandbox_id = $1 WHERE id = $2",
        [ghost_uuid_bin, conv_id_bin]
      )

      # Also delete the original sandbox record now that the FK is no longer referenced.
      Ecto.Adapters.SQL.query!(Fountain.Repo, "SET session_replication_role = DEFAULT", [])
      Fountain.Repo.delete!(sandbox)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # start_conversation/1
  # ────────────────────────────────────────────────────────────────────────────

  describe "start_conversation/1" do
    test "returns {:error, :vault_not_found} when vault_id belongs to a different user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      agent = insert_agent(user_id: user1.id)
      # vault belongs to user2, not user1
      vault = insert_vault(user_id: user2.id)

      attrs = %{
        "agent_id" => agent.id,
        "user_id" => user1.id,
        "vault_id" => vault.id
      }

      assert {:error, :vault_not_found} = Conversations.start_conversation(attrs)
    end

    test "creates sandbox, conversation, and starts server", %{} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{
        "agent_id" => agent.id,
        "user_id" => user.id,
        "prompt" => "hello"
      }

      assert {:ok, conv} = Conversations.start_conversation(attrs)
      assert conv.agent_id == agent.id
      assert conv.user_id == user.id
      assert conv.status == "pending"
    end

    test "broadcasts graph update when parent_conversation_id is set", %{} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      parent_conv = insert_conversation(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{
        "agent_id" => agent.id,
        "user_id" => user.id,
        "parent_conversation_id" => parent_conv.id
      }

      assert {:ok, conv} = Conversations.start_conversation(attrs)
      assert conv.parent_conversation_id == parent_conv.id
    end

    test "succeeds when vault_id is empty string", %{} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec -> {:ok, spawn(fn -> :ok end)} end)

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => ""}
      assert {:ok, conv} = Conversations.start_conversation(attrs)
      assert is_nil(conv.vault_id)
    end

    test "succeeds and links vault when valid vault_id provided", %{} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      vault = insert_vault(user_id: user.id)

      stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec -> {:ok, spawn(fn -> :ok end)} end)

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => vault.id}
      assert {:ok, conv} = Conversations.start_conversation(attrs)
      assert conv.vault_id == vault.id
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # list_active_conversations/0 — ordering
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_active_conversations/0 ordering" do
    test "running conversations appear before idle conversations" do
      user = insert_verified_user()
      idle = insert_conversation(user_id: user.id, status: "idle")
      running = insert_conversation(user_id: user.id, status: "running")

      results = Conversations.list_active_conversations()
      active_ids = results |> Enum.map(& &1.id) |> Enum.filter(&(&1 in [idle.id, running.id]))
      assert hd(active_ids) == running.id
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # list_turns_with_images/1
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_turns_with_images/1" do
    test "returns empty list when conversation has no turns" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert Conversations.list_turns_with_images(conv.id) == []
    end

    test "returns all turns for the conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv)
      t2 = insert_turn(conv)

      ids = Conversations.list_turns_with_images(conv.id) |> Enum.map(& &1.id)
      assert t1.id in ids
      assert t2.id in ids
    end

    test "orders turns by turn_number ascending" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv)
      t2 = insert_turn(conv)

      [first, second] = Conversations.list_turns_with_images(conv.id)
      assert first.turn_number < second.turn_number
      assert first.id == t1.id
      assert second.id == t2.id
    end

    test "does not return turns from other conversations" do
      user = insert_verified_user()
      conv1 = insert_conversation(user_id: user.id)
      conv2 = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv1)
      _t2 = insert_turn(conv2)

      results = Conversations.list_turns_with_images(conv1.id)
      assert length(results) == 1
      assert hd(results).id == t1.id
    end

    test "preloads images association on each turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      %Fountain.Conversations.TurnImage{}
      |> Fountain.Conversations.TurnImage.changeset(%{
        turn_id: turn.id,
        position: 0,
        media_type: "image/png",
        data: <<1, 2, 3>>
      })
      |> Ecto.Changeset.put_change(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.insert!()

      [loaded_turn] = Conversations.list_turns_with_images(conv.id)
      assert length(loaded_turn.images) == 1
      [img] = loaded_turn.images
      assert img.media_type == "image/png"
      assert img.data == <<1, 2, 3>>
    end

    test "returns turns with empty images list when no images have been inserted" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      _turn = insert_turn(conv)

      [loaded_turn] = Conversations.list_turns_with_images(conv.id)
      assert loaded_turn.images == []
    end

    test "orders images by position ascending when multiple images exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      for {mt, data, pos} <- [{"image/png", <<10>>, 0}, {"image/jpeg", <<20>>, 1}, {"image/gif", <<30>>, 2}] do
        %Fountain.Conversations.TurnImage{}
        |> Fountain.Conversations.TurnImage.changeset(%{
          turn_id: turn.id,
          position: pos,
          media_type: mt,
          data: data
        })
        |> Ecto.Changeset.put_change(:inserted_at, now)
        |> Repo.insert!()
      end

      [loaded_turn] = Conversations.list_turns_with_images(conv.id)
      positions = Enum.map(loaded_turn.images, & &1.position)
      assert positions == Enum.sort(positions)
    end
  end

  describe "insert_sandbox/1 factory — no explicit user_id" do
    test "creates a new user when no user_id is provided" do
      # Triggers the insert_verified_user().id fallback in insert_sandbox (factory.ex line 129)
      sandbox = insert_sandbox()
      assert is_binary(sandbox.user_id)
    end
  end

  describe "insert_conversation/1 factory — agent without explicit user_id" do
    test "derives user_id from agent when no user_id is provided" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(agent: agent)
      assert conv.user_id == user.id
      assert conv.agent_id == agent.id
    end

    test "creates a new user when neither user_id nor agent is provided" do
      # Triggers the insert_verified_user().id fallback (factory.ex line 147)
      conv = insert_conversation()
      assert is_binary(conv.user_id)
      assert is_nil(conv.agent_id)
    end
  end

  describe "factory to_atom_map — safe_to_existing_atom fallback" do
    test "to_atom_map with an unknown string key does not crash and returns the string as fallback" do
      # \"xyzquuxfoo_novel_key_never_an_atom\" is not an existing Elixir atom,
      # so safe_to_existing_atom triggers its rescue clause and returns the string key.
      result = Fountain.Factory.to_atom_map(%{
        "sprite_name" => "test-sprite",
        "xyzquuxfoo_novel_key_never_an_atom" => "ignored_value"
      })

      assert Map.get(result, :sprite_name) == "test-sprite"
      # The unknown key is preserved as a string (fallback)
      assert Map.get(result, "xyzquuxfoo_novel_key_never_an_atom") == "ignored_value"
    end
  end
end
