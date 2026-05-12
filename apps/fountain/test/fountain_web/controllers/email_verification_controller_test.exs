defmodule FountainWeb.EmailVerificationControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Accounts
  alias Fountain.Repo

  describe "GET /users/confirm/:token" do
    test "verifies email, sets session, and redirects to onboarding for new user", %{conn: conn} do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/onboarding/step_1"
      assert get_session(conn, :user_id) == user.id

      # User should be verified in DB
      updated = Accounts.get_user!(user.id)
      refute is_nil(updated.email_verified_at)
    end

    test "redirects already-verified user without onboarding_completed_at to onboarding", %{conn: conn} do
      user = insert_verified_user()
      assert is_nil(user.onboarding_completed_at)

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/onboarding/step_1"
      assert get_session(conn, :user_id) == user.id
    end

    test "redirects already-verified user with onboarding_completed_at to dashboard", %{conn: conn} do
      user = insert_verified_user()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, user_with_onboarding} = Repo.update(Ecto.Changeset.change(user, onboarding_completed_at: now))

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user_with_onboarding.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id) == user_with_onboarding.id
    end

    test "redirects with error when user no longer exists in database", %{conn: conn} do
      # Sign a token with a UUID that doesn't correspond to any user
      missing_id = Ecto.UUID.generate()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", missing_id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "redirects with error for expired token", %{conn: conn} do
      user = insert_user()

      # Sign the token as if it were issued 2 days ago (> 24h max_age).
      # Phoenix.Token.sign/4 accepts `signed_at:` in seconds.
      two_days_ago = System.system_time(:second) - 2 * 24 * 60 * 60
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id, signed_at: two_days_ago)

      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/users/confirm/thisisnotavalidtoken")
      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "redirects with error when verify_email returns an error changeset", %{conn: conn} do
      user = insert_user()

      # Stub Accounts.verify_email/1 to simulate a DB-level failure so that
      # line 53 (the {:error, _changeset} branch) is exercised.
      stub(Accounts, :verify_email, fn _user ->
        changeset =
          %Fountain.Accounts.User{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:email, "simulated failure")
        {:error, changeset}
      end)

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "went wrong"
    end
  end
end
