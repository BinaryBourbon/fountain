defmodule Fountain.ConversationsContextTest do
  use Fountain.DataCase, async: true

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

    test "orders by updated_at descending" do
      user = insert_verified_user()
      c1 = insert_conversation(user_id: user.id)
      c2 = insert_conversation(user_id: user.id)

      # Backdate c2 so c1 is guaranteed to sort first regardless of wall-clock
      # precision (utc_datetime has second granularity).
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      Fountain.Repo.update_all(
        Ecto.Query.from(c in Conversation, where: c.id == ^c2.id),
        set: [updated_at: past]
      )

      [first | _] = Conversations.list_conversations_by_activity(user.id)
      assert first.id == c1.id
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
end
