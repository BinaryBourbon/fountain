defmodule Fountain.AccountsCredentialTest do
  @moduledoc """
  Logged-in credential management (#448): change password, verified email
  change. The properties that matter: the current password gates both, the
  email never changes without proof of control of the new address, and
  neither flow leaks whether an address is taken.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Workers.EmailChangeEmail

  defp oauth_only_user do
    {:ok, user, :new} =
      Accounts.upsert_oauth_user("github", "uid-#{System.unique_integer([:positive])}", %{
        "email" => "oauth#{System.unique_integer([:positive])}@example.com"
      })

    user
  end

  describe "change_password/3" do
    test "changes the password and invalidates other sessions" do
      user = insert_verified_user(%{"password" => "old-password-123"})

      assert {:ok, updated} =
               Accounts.change_password(user, "old-password-123", "new-password-456")

      assert updated.session_version > user.session_version
      assert {:ok, _} = Accounts.authenticate_user(user.email, "new-password-456")

      assert {:error, :wrong_password} =
               Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "refuses a wrong current password without touching anything" do
      user = insert_verified_user(%{"password" => "old-password-123"})

      assert {:error, :invalid_current_password} =
               Accounts.change_password(user, "not-the-password", "new-password-456")

      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "a too-short new password comes back as a changeset error" do
      user = insert_verified_user(%{"password" => "old-password-123"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.change_password(user, "old-password-123", "short")
    end

    test "an OAuth-only account has no password to change" do
      assert {:error, :no_password} =
               Accounts.change_password(oauth_only_user(), "anything", "new-password-456")
    end
  end

  describe "request_email_change/3" do
    test "enqueues the confirmation when the address is free" do
      user = insert_verified_user(%{"password" => "password-123"})

      assert :ok = Accounts.request_email_change(user, "Fresh@Example.com", "password-123")

      # downcased before it reaches the job
      assert_enqueued(
        worker: EmailChangeEmail,
        args: %{kind: "confirmation", user_id: user.id, new_email: "fresh@example.com"}
      )
    end

    test "returns :ok for a taken address but enqueues nothing — no oracle" do
      user = insert_verified_user(%{"password" => "password-123"})
      other = insert_verified_user()

      assert :ok = Accounts.request_email_change(user, other.email, "password-123")
      refute_enqueued(worker: EmailChangeEmail)
    end

    test "the current password gates the request" do
      user = insert_verified_user(%{"password" => "password-123"})

      assert {:error, :invalid_current_password} =
               Accounts.request_email_change(user, "new@example.com", "wrong")

      refute_enqueued(worker: EmailChangeEmail)
    end

    test "rejects a non-address and the account's own address" do
      user = insert_verified_user(%{"password" => "password-123"})

      assert {:error, :invalid_email} =
               Accounts.request_email_change(user, "not an email", "password-123")

      assert {:error, :same_email} =
               Accounts.request_email_change(user, user.email, "password-123")
    end

    test "an OAuth-only account cannot change its email" do
      assert {:error, :no_password} =
               Accounts.request_email_change(oauth_only_user(), "new@example.com", "x")
    end
  end

  describe "apply_email_change/1" do
    test "changes the email, stamps verification, kills sessions, notifies the old address" do
      user = insert_verified_user()
      token = Accounts.email_change_token(user, "changed@example.com")

      assert {:ok, updated, old_email} = Accounts.apply_email_change(token)

      assert updated.email == "changed@example.com"
      assert old_email == user.email
      assert updated.email_verified_at
      assert updated.session_version > user.session_version

      assert_enqueued(
        worker: EmailChangeEmail,
        args: %{kind: "notice", old_email: user.email, new_email: "changed@example.com"}
      )
    end

    test "a token outlives neither its TTL nor a session_version bump" do
      user = insert_verified_user(%{"password" => "password-123"})
      token = Accounts.email_change_token(user, "changed@example.com")

      # A password change (or a completed email change, or a suspension)
      # bumps session_version, and the token was issued against the old one.
      {:ok, _} = Accounts.change_password(user, "password-123", "another-password-9")

      assert {:error, :invalid} = Accounts.apply_email_change(token)
    end

    test "an address claimed between request and click fails cleanly" do
      user = insert_verified_user()
      token = Accounts.email_change_token(user, "claimed@example.com")
      insert_verified_user(%{"email" => "claimed@example.com"})

      assert {:error, :email_taken} = Accounts.apply_email_change(token)
      assert Repo.reload(user).email == user.email
    end

    test "garbage tokens are invalid, not crashes" do
      assert {:error, :invalid} = Accounts.apply_email_change("not-a-token")
    end
  end
end
