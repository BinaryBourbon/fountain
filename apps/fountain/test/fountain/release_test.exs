defmodule Fountain.ReleaseTest do
  use Fountain.DataCase, async: true

  import ExUnit.CaptureIO

  alias Fountain.Release

  # Puts a user into an explicit billing state, bypassing the registration
  # changeset — these combinations exist in production but are not all
  # reachable through the public API.
  defp put_billing(user, status, trial_ends_at) do
    user
    |> Ecto.Changeset.change(subscription_status: status, trial_ends_at: trial_ends_at)
    |> Repo.update!()
  end

  describe "expire_legacy_trials/1" do
    test "dry run reports the count and writes nothing" do
      # Registration has set trial_ends_at since #244, so the legacy state —
      # trialing with no deadline — has to be constructed directly.
      user = put_billing(insert_user(), "trialing", nil)

      capture_io(fn ->
        assert {:ok, count} = Release.expire_legacy_trials(dry_run: true)
        # Other async tests insert users too, so exact equality would race.
        assert count >= 1
      end)

      assert is_nil(Repo.reload!(user).trial_ends_at)
    end

    test "sets trial_ends_at counted from now, only on NULL-trial trialing users" do
      legacy = put_billing(insert_user(), "trialing", nil)
      already_dated = put_billing(insert_user(), "trialing", ~U[2027-01-01 00:00:00Z])
      active = put_billing(insert_user(), "active", nil)

      capture_io(fn ->
        assert {:ok, count} = Release.expire_legacy_trials(days: 14)
        assert count >= 1
      end)

      ends_at = Repo.reload!(legacy).trial_ends_at
      refute is_nil(ends_at)

      # Counted from now, not from signup: within a minute of now + 14 days.
      expected = DateTime.add(DateTime.utc_now(), 14 * 24 * 60 * 60, :second)
      assert abs(DateTime.diff(ends_at, expected, :second)) < 60

      assert Repo.reload!(already_dated).trial_ends_at == ~U[2027-01-01 00:00:00Z]
      assert is_nil(Repo.reload!(active).trial_ends_at)
    end

    test "starts a trial for accounts registered while billing was disabled (#480)" do
      # Those accounts have no status at all; after enabling billing they fail
      # closed at the gate until this runs.
      community = put_billing(insert_user(), nil, nil)
      active = put_billing(insert_user(), "active", nil)

      capture_io(fn ->
        assert {:ok, count} = Release.expire_legacy_trials(days: 14)
        assert count >= 1
      end)

      reloaded = Repo.reload!(community)
      assert reloaded.subscription_status == "trialing"
      assert %DateTime{} = reloaded.trial_ends_at

      assert Repo.reload!(active).subscription_status == "active"
    end
  end

  describe "verify_email/1" do
    test "verifies an existing account" do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      capture_io(fn ->
        assert {:ok, verified} = Release.verify_email(user.email)
        assert %DateTime{} = verified.email_verified_at
      end)
    end

    test "returns not_found for an unknown email" do
      capture_io(:stderr, fn ->
        assert {:error, :not_found} =
                 Release.verify_email("nobody-#{System.unique_integer([:positive])}@example.com")
      end)
    end
  end

  describe "promote_admin/1" do
    import Ecto.Query

    defp admin_events_for(user_id) do
      Repo.all(
        from e in Fountain.Audit.AdminEvent,
          where: e.target_user_id == ^user_id and e.event_type == "admin.role.granted"
      )
    end

    test "grants the role and records a system-actor audit event" do
      user = insert_user()
      assert user.role == "user"

      capture_io(fn ->
        assert {:ok, promoted} = Release.promote_admin(user.email)
        assert promoted.role == "admin"
      end)

      assert Repo.reload!(user).role == "admin"

      assert [event] = admin_events_for(user.id)
      assert is_nil(event.actor_user_id)
      assert event.metadata["email"] == user.email
      assert event.metadata["via"] == "release_task"
      assert event.metadata["to"] == "admin"
    end

    test "an already-admin account is a no-op and records nothing" do
      user = insert_user()

      capture_io(fn ->
        assert {:ok, _} = Release.promote_admin(user.email)
        assert {:ok, again} = Release.promote_admin(user.email)
        assert again.role == "admin"
      end)

      # Only the first call recorded an event.
      assert [_one] = admin_events_for(user.id)
    end

    test "returns not_found for an unknown email" do
      capture_io(:stderr, fn ->
        assert {:error, :not_found} =
                 Release.promote_admin("nobody-#{System.unique_integer([:positive])}@example.com")
      end)
    end
  end
end
