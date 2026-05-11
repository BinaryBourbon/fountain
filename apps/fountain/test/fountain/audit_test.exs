defmodule Fountain.AuditTest do
  use Fountain.DataCase, async: true

  alias Fountain.Audit

  defp valid_attrs(user_id, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user_id,
        action: "test.action",
        resource_type: "agent",
        resource_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  describe "record/1" do
    test "records an audit event" do
      user = insert_verified_user()
      attrs = valid_attrs(user.id)

      assert {:ok, event} = Audit.record(attrs)
      assert event.user_id == user.id
      assert event.action == "test.action"
    end

    test "returns error tuple for missing required fields" do
      assert {:error, _} = Audit.record(%{})
    end
  end

  describe "record!/1" do
    test "records an audit event" do
      user = insert_verified_user()
      attrs = valid_attrs(user.id)

      assert event = Audit.record!(attrs)
      assert event.user_id == user.id
    end

    test "raises MatchError on invalid attrs" do
      # record!/1 does {:ok, event} = record(attrs), so invalid attrs raise MatchError
      assert_raise MatchError, fn ->
        Audit.record!(%{})
      end
    end
  end

  describe "list_recent_for_user/2" do
    test "returns events for the given user, newest first" do
      user = insert_verified_user()
      resource_id = Ecto.UUID.generate()

      {:ok, first} = Audit.record(valid_attrs(user.id, %{resource_id: resource_id, action: "first"}))
      {:ok, second} = Audit.record(valid_attrs(user.id, %{resource_id: resource_id, action: "second"}))

      events = Audit.list_recent_for_user(user.id)
      ids = Enum.map(events, & &1.id)

      assert second.id in ids
      assert first.id in ids
      assert Enum.find_index(ids, &(&1 == second.id)) < Enum.find_index(ids, &(&1 == first.id))
    end

    test "does not return events for other users" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()

      Audit.record(valid_attrs(user_a.id))

      assert Audit.list_recent_for_user(user_b.id) == []
    end

    test "respects limit" do
      user = insert_verified_user()

      for _ <- 1..5 do
        Audit.record(valid_attrs(user.id))
      end

      events = Audit.list_recent_for_user(user.id, 3)
      assert length(events) == 3
    end
  end

  describe "list_for/4" do
    test "returns events for a specific resource" do
      user = insert_verified_user()
      resource_id = Ecto.UUID.generate()
      other_resource_id = Ecto.UUID.generate()

      Audit.record(valid_attrs(user.id, %{resource_id: resource_id}))
      Audit.record(valid_attrs(user.id, %{resource_id: other_resource_id}))

      events = Audit.list_for("agent", resource_id, user.id)
      assert length(events) == 1
      assert hd(events).resource_id == resource_id
    end

    test "does not return events for same resource but different user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      resource_id = Ecto.UUID.generate()

      Audit.record(valid_attrs(user_a.id, %{resource_id: resource_id}))

      assert Audit.list_for("agent", resource_id, user_b.id) == []
    end

    test "respects limit" do
      user = insert_verified_user()
      resource_id = Ecto.UUID.generate()

      for _ <- 1..10 do
        Audit.record(valid_attrs(user.id, %{resource_id: resource_id}))
      end

      events = Audit.list_for("agent", resource_id, user.id, 4)
      assert length(events) == 4
    end
  end
end
