defmodule Fountain.AccountsAdditionalTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey

  import Fountain.Factory

  # ── get_user_by_email/1 ─────────────────────────────────────────────────────

  describe "get_user_by_email/1" do
    test "returns the user when the email matches" do
      user = insert_verified_user()
      assert %{id: id} = Accounts.get_user_by_email(user.email)
      assert id == user.id
    end

    test "is case-insensitive (downcases before lookup)" do
      user = insert_verified_user()
      upper_email = String.upcase(user.email)
      assert %{id: id} = Accounts.get_user_by_email(upper_email)
      assert id == user.id
    end

    test "returns nil when no user exists for the given email" do
      assert Accounts.get_user_by_email("nobody@example.com") == nil
    end
  end

  # ── get_user/1 and get_user!/1 ──────────────────────────────────────────────

  describe "get_user/1" do
    test "returns the user struct for a valid id" do
      user = insert_verified_user()
      assert %{id: id} = Accounts.get_user(user.id)
      assert id == user.id
    end

    test "returns nil for an unknown id" do
      assert Accounts.get_user(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_user!/1" do
    test "returns the user struct for a valid id" do
      user = insert_verified_user()
      assert %{id: id} = Accounts.get_user!(user.id)
      assert id == user.id
    end

    test "raises Ecto.NoResultsError for an unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end
  end

  # ── create_api_key/2 ────────────────────────────────────────────────────────

  describe "create_api_key/2" do
    test "returns {:ok, {key_record, raw_key}} with ftn_ prefix" do
      user = insert_verified_user()
      assert {:ok, {%ApiKey{} = key, raw_key}} = Accounts.create_api_key(user.id, "my-key")

      assert String.starts_with?(raw_key, "ftn_")
      assert key.user_id == user.id
      assert key.name == "my-key"
      assert is_nil(key.revoked_at)
    end

    test "stores only the hash and prefix, not the raw key" do
      user = insert_verified_user()
      {:ok, {key, raw_key}} = Accounts.create_api_key(user.id, "test")

      assert key.key_hash == Accounts.hash_key(raw_key)
      assert key.key_prefix == String.slice(raw_key, 0, 8)
      refute Map.has_key?(Map.from_struct(key), :raw_key)
    end

    test "each call generates a unique raw key" do
      user = insert_verified_user()
      {:ok, {_, raw1}} = Accounts.create_api_key(user.id, "k1")
      {:ok, {_, raw2}} = Accounts.create_api_key(user.id, "k2")
      assert raw1 != raw2
    end

    test "returns error changeset when name is blank" do
      user = insert_verified_user()
      assert {:error, changeset} = Accounts.create_api_key(user.id, "")
      assert changeset.errors[:name]
    end
  end

  # ── list_api_keys/1 ─────────────────────────────────────────────────────────

  describe "list_api_keys/1" do
    test "returns all active keys for a user" do
      user = insert_verified_user()
      {:ok, {k1, _}} = Accounts.create_api_key(user.id, "key-a")
      {:ok, {k2, _}} = Accounts.create_api_key(user.id, "key-b")

      ids = Accounts.list_api_keys(user.id) |> Enum.map(& &1.id)
      assert k1.id in ids
      assert k2.id in ids
    end

    test "does not include revoked keys" do
      user = insert_verified_user()
      {:ok, {key, _raw}} = Accounts.create_api_key(user.id, "will-be-revoked")
      {:ok, _} = Accounts.revoke_api_key(user.id, key.id)

      ids = Accounts.list_api_keys(user.id) |> Enum.map(& &1.id)
      refute key.id in ids
    end

    test "returns empty list when user has no active keys" do
      user = insert_verified_user()
      assert Accounts.list_api_keys(user.id) == []
    end

    test "does not return keys belonging to another user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      {:ok, {key2, _}} = Accounts.create_api_key(user2.id, "other-key")

      ids = Accounts.list_api_keys(user1.id) |> Enum.map(& &1.id)
      refute key2.id in ids
    end
  end

  # ── revoke_api_key/2 ────────────────────────────────────────────────────────

  describe "revoke_api_key/2" do
    test "sets revoked_at on the key" do
      user = insert_verified_user()
      {:ok, {key, _raw}} = Accounts.create_api_key(user.id, "to-revoke")

      assert {:ok, revoked_key} = Accounts.revoke_api_key(user.id, key.id)
      assert revoked_key.id == key.id
      assert revoked_key.revoked_at != nil
    end

    test "returns {:error, :not_found} for a nonexistent key id" do
      user = insert_verified_user()
      assert {:error, :not_found} = Accounts.revoke_api_key(user.id, Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} when key belongs to another user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      {:ok, {key, _raw}} = Accounts.create_api_key(user2.id, "someone-elses-key")

      assert {:error, :not_found} = Accounts.revoke_api_key(user1.id, key.id)
    end
  end

  # ── get_user_by_api_key/1 ───────────────────────────────────────────────────

  describe "get_user_by_api_key/1" do
    test "returns {:ok, user} for a valid active key" do
      user = insert_verified_user()
      {:ok, {_key, raw_key}} = Accounts.create_api_key(user.id, "active")

      assert {:ok, returned_user} = Accounts.get_user_by_api_key(raw_key)
      assert returned_user.id == user.id
    end

    test "returns {:error, :invalid} for an unknown key" do
      fake_raw = "ftn_" <> String.duplicate("a", 64)
      assert {:error, :invalid} = Accounts.get_user_by_api_key(fake_raw)
    end

    test "returns {:error, :invalid} for a revoked key" do
      user = insert_verified_user()
      {:ok, {key, raw_key}} = Accounts.create_api_key(user.id, "revokeme")
      {:ok, _} = Accounts.revoke_api_key(user.id, key.id)

      assert {:error, :invalid} = Accounts.get_user_by_api_key(raw_key)
    end
  end

  # ── reset_password/2 ────────────────────────────────────────────────────────

  describe "reset_password/2" do
    test "updates the password hash" do
      user = insert_verified_user()
      old_hash = user.password_hash

      assert {:ok, updated} = Accounts.reset_password(user, "newpassword123")
      assert updated.password_hash != old_hash
    end

    test "bumps session_version to invalidate existing sessions" do
      user = insert_verified_user()

      assert {:ok, updated} = Accounts.reset_password(user, "newpassword123")
      assert updated.session_version > user.session_version
    end

    test "new password can be used to authenticate" do
      user = insert_verified_user()
      {:ok, _} = Accounts.reset_password(user, "mynewpassword!")

      assert {:ok, _} = Accounts.authenticate_user(user.email, "mynewpassword!")
    end

    test "old password no longer works after reset" do
      user = insert_verified_user(%{"password" => "oldpassword1"})
      {:ok, _} = Accounts.reset_password(user, "newpassword123")

      assert {:error, :wrong_password} = Accounts.authenticate_user(user.email, "oldpassword1")
    end

    test "returns error changeset when new password is too short" do
      user = insert_verified_user()
      assert {:error, changeset} = Accounts.reset_password(user, "short")
      assert changeset.errors[:password]
    end
  end

  # ── list_users/0 ────────────────────────────────────────────────────────────

  describe "list_users/0" do
    test "returns all users ordered by insertion date" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()

      ids = Accounts.list_users() |> Enum.map(& &1.id)
      assert user1.id in ids
      assert user2.id in ids

      # user1 was inserted first so should appear before user2
      assert Enum.find_index(ids, &(&1 == user1.id)) <
               Enum.find_index(ids, &(&1 == user2.id))
    end
  end

  # ── update_user_role/2 ──────────────────────────────────────────────────────

  describe "update_user_role/2" do
    test "promotes a user to admin" do
      user = insert_verified_user()
      assert {:ok, updated} = Accounts.update_user_role(user, "admin")
      assert updated.role == "admin"
    end

    test "demotes an admin back to user" do
      user = insert_verified_user(%{"role" => "admin"})
      assert {:ok, updated} = Accounts.update_user_role(user, "user")
      assert updated.role == "user"
    end
  end

  # ── authenticate_user/2 ─────────────────────────────────────────────────────

  describe "authenticate_user/2" do
    test "returns {:ok, user} for valid email and password" do
      user = insert_verified_user(%{"password" => "correcthorse"})
      assert {:ok, returned} = Accounts.authenticate_user(user.email, "correcthorse")
      assert returned.id == user.id
    end

    test "returns {:error, :wrong_password} when password does not match" do
      user = insert_verified_user(%{"password" => "correcthorse"})
      assert {:error, :wrong_password} = Accounts.authenticate_user(user.email, "wrongpassword")
    end

    test "returns {:error, :not_found} when no user exists with that email" do
      assert {:error, :not_found} = Accounts.authenticate_user("nobody@nowhere.test", "anypassword")
    end
  end

  # ── verify_email/1 ──────────────────────────────────────────────────────────

  describe "verify_email/1" do
    test "sets email_verified_at to a non-nil datetime" do
      {:ok, user} = Fountain.Accounts.register_user(%{"email" => "unverified#{System.unique_integer([:positive])}@example.com", "password" => "password123"})
      assert is_nil(user.email_verified_at)

      assert {:ok, verified} = Accounts.verify_email(user)
      assert %DateTime{} = verified.email_verified_at
    end

    test "calling verify_email again on an already-verified user succeeds" do
      user = insert_verified_user()
      assert {:ok, _} = Accounts.verify_email(user)
    end
  end

  # ── complete_onboarding/1 ───────────────────────────────────────────────────

  describe "complete_onboarding/1" do
    test "sets onboarding_state to 'completed' and onboarding_completed_at to a datetime" do
      user = insert_verified_user()
      assert is_nil(user.onboarding_completed_at)

      assert {:ok, updated} = Accounts.complete_onboarding(user)
      assert updated.onboarding_state == "completed"
      assert %DateTime{} = updated.onboarding_completed_at
    end
  end

  # ── advance_onboarding/2 ────────────────────────────────────────────────────

  describe "advance_onboarding/2" do
    test "advances to step_1 and only sets onboarding_state" do
      user = insert_verified_user()
      assert {:ok, updated} = Accounts.advance_onboarding(user, "step_1")
      assert updated.onboarding_state == "step_1"
      assert is_nil(updated.onboarding_completed_at)
    end

    test "advances to step_3 and only sets onboarding_state" do
      user = insert_verified_user()
      assert {:ok, updated} = Accounts.advance_onboarding(user, "step_3")
      assert updated.onboarding_state == "step_3"
      assert is_nil(updated.onboarding_completed_at)
    end

    test "advancing to 'completed' also sets onboarding_completed_at" do
      user = insert_verified_user()
      assert {:ok, updated} = Accounts.advance_onboarding(user, "completed")
      assert updated.onboarding_state == "completed"
      assert %DateTime{} = updated.onboarding_completed_at
    end
  end

  # ── touch_api_key/1 ─────────────────────────────────────────────────────────

  describe "touch_api_key/1" do
    test "returns :ok and updates last_used_at" do
      user = insert_verified_user()
      {:ok, {key, raw_key}} = Accounts.create_api_key(user.id, "touchme")
      assert is_nil(key.last_used_at)

      assert :ok = Accounts.touch_api_key(raw_key)

      updated = Fountain.Repo.get!(ApiKey, key.id)
      assert updated.last_used_at != nil
    end

    test "returns :ok silently for an unknown key (no error)" do
      fake_raw = "ftn_" <> String.duplicate("b", 64)
      assert :ok = Accounts.touch_api_key(fake_raw)
    end
  end

  # ── upsert_oauth_user/3 ─────────────────────────────────────────────────────

  describe "upsert_oauth_user/3" do
    test "creates a brand-new user when neither identity nor email exists" do
      email = "oauth_new_#{System.unique_integer([:positive])}@example.com"
      attrs = %{"email" => email, "name" => "OAuth User"}

      assert {:ok, user, :new} =
               Accounts.upsert_oauth_user("github", "uid_#{System.unique_integer()}", attrs)

      assert user.email == email
      assert user.email_verified_at != nil
      # UserDataKey should have been created automatically
      assert {:ok, _dek} = Fountain.Crypto.load_tenant_key(user.id)
    end

    test "links an existing user when email matches but no OauthIdentity exists" do
      existing_user = insert_verified_user()

      assert {:ok, user, :existing} =
               Accounts.upsert_oauth_user("github", "uid_#{System.unique_integer()}", %{
                 "email" => existing_user.email
               })

      assert user.id == existing_user.id
    end

    test "returns :existing when the OauthIdentity already exists" do
      existing_user = insert_verified_user()
      provider_uid = "uid_#{System.unique_integer()}"

      # First call creates identity
      {:ok, _, :existing} =
        Accounts.upsert_oauth_user("github", provider_uid, %{"email" => existing_user.email})

      # Second call reuses existing identity
      assert {:ok, user, :existing} =
               Accounts.upsert_oauth_user("github", provider_uid, %{"email" => existing_user.email})

      assert user.id == existing_user.id
    end
  end
end
