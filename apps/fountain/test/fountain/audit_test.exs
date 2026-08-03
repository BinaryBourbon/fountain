defmodule Fountain.AuditTest do
  use Fountain.DataCase, async: true

  import ExUnit.CaptureLog

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

  describe "_unsafe_list_recent/1" do
    test "returns all events across all users" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      Audit.record!(valid_attrs(user1.id))
      Audit.record!(valid_attrs(user2.id))

      events = Audit._unsafe_list_recent()
      user_ids = Enum.map(events, & &1.user_id)
      assert user1.id in user_ids
      assert user2.id in user_ids
    end

    test "respects the limit parameter" do
      user = insert_verified_user()
      for _ <- 1..5, do: Audit.record!(valid_attrs(user.id))

      assert length(Audit._unsafe_list_recent(3)) == 3
    end
  end

  describe "record/1 — exception rescue" do
    test "returns {:error, :exception} when attrs cause a runtime exception" do
      # Passing a non-enumerable triggers Protocol.UndefinedError inside cast,
      # which is rescued and returns {:error, :exception} with a warning log.
      assert {:error, :exception} = Audit.record(:not_a_map)
    end
  end

  describe "record_admin/1 — rejected writes are loud (#451)" do
    test "an unknown event type is rejected with an error log, not silently" do
      actor = insert_verified_user()

      log =
        capture_log(fn ->
          assert {:error, %Ecto.Changeset{}} =
                   Audit.record_admin(%{
                     actor_user_id: actor.id,
                     target_user_id: nil,
                     event_type: "admin.not.in.the.allowlist"
                   })
        end)

      assert log =~ "REJECTED"
      assert log =~ "admin.not.in.the.allowlist"
    end

    test "a rejected write emits the admin_record_rejected telemetry event" do
      test_pid = self()
      handler_id = "audit-reject-#{inspect(self())}"

      :telemetry.attach(
        handler_id,
        [:fountain, :audit, :admin_record_rejected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:rejected, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log(fn ->
        Audit.record_admin(%{event_type: "admin.also.unknown"})
      end)

      assert_receive {:rejected, %{count: 1}, %{event_type: "admin.also.unknown"}}
    end

    test "a valid write emits nothing and logs nothing" do
      actor = insert_verified_user()

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Audit.record_admin(%{
                     actor_user_id: actor.id,
                     event_type: "admin.account.suspended",
                     metadata: %{"email" => "x@example.com"}
                   })
        end)

      refute log =~ "REJECTED"
    end
  end
end
