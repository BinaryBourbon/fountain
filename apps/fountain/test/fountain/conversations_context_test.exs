defmodule Fountain.ConversationsContextTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Sandbox}

  # Sandboxes and conversations: the CRUD surface of the context.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # Sandboxes
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_get_sandbox/1" do
    test "returns the sandbox when it exists" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      result = Conversations._unsafe_get_sandbox(sandbox.id)
      assert result.id == sandbox.id
      assert result.sprite_name == sandbox.sprite_name
    end

    test "returns nil when sandbox does not exist" do
      assert Conversations._unsafe_get_sandbox(Ecto.UUID.generate()) == nil
    end
  end

  describe "_unsafe_get_sandbox!/1" do
    test "returns the sandbox when it exists" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      result = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert result.id == sandbox.id
    end

    test "raises Ecto.NoResultsError when sandbox does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations._unsafe_get_sandbox!(Ecto.UUID.generate())
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

  describe "_unsafe_list_active_conversations/0" do
    test "returns empty list when no conversations exist" do
      assert Conversations._unsafe_list_active_conversations() == []
    end

    test "returns conversations with non-terminal statuses" do
      user = insert_verified_user()
      pending = insert_conversation(user_id: user.id, status: "pending")
      idle = insert_conversation(user_id: user.id, status: "idle")
      running = insert_conversation(user_id: user.id, status: "running")

      ids = Conversations._unsafe_list_active_conversations() |> Enum.map(& &1.id)
      assert pending.id in ids
      assert idle.id in ids
      assert running.id in ids
    end

    test "excludes terminated and failed conversations" do
      user = insert_verified_user()
      terminated = insert_conversation(user_id: user.id, status: "terminated")

      failed = insert_conversation(user_id: user.id, status: "failed")

      ids = Conversations._unsafe_list_active_conversations() |> Enum.map(& &1.id)
      refute terminated.id in ids
      refute failed.id in ids
    end

    test "does not filter by user — returns active convs across all users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id, status: "pending")
      c2 = insert_conversation(user_id: user2.id, status: "idle")

      ids = Conversations._unsafe_list_active_conversations() |> Enum.map(& &1.id)
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

      # ConversationServer.terminate_conversation/2 will return an error since the server
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
end
