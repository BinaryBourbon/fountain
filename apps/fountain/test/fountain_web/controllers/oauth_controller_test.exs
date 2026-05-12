defmodule FountainWeb.UeberauthControllerTest do
  @moduledoc """
  Tests for the GitHub OAuth callback flow.

  We mock the Ueberauth assigns that the Ueberauth plug would normally
  set, bypassing the real OAuth round-trip.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Accounts

  # Simulate a successful Ueberauth auth struct from GitHub
  defp github_auth(email, uid \\ nil) do
    uid = uid || "gh_#{System.unique_integer([:positive])}"

    %Ueberauth.Auth{
      provider: :github,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: email},
      credentials: %Ueberauth.Auth.Credentials{},
      extra: %Ueberauth.Auth.Extra{}
    }
  end

  defp github_failure do
    %Ueberauth.Failure{
      provider: :github,
      strategy: Ueberauth.Strategy.Github,
      errors: [%Ueberauth.Failure.Error{message: "OAuth error", message_key: "error"}]
    }
  end

  defp assign_auth(conn, auth) do
    Plug.Conn.assign(conn, :ueberauth_auth, auth)
  end

  defp assign_failure(conn, failure) do
    Plug.Conn.assign(conn, :ueberauth_failure, failure)
  end

  describe "callback/2 — success (new user)" do
    test "creates user, sets session, redirects to onboarding", %{conn: conn} do
      email = "github_new_#{System.unique_integer()}@example.com"
      auth = github_auth(email)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_auth(auth)
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/onboarding/step_1"
      user_id = get_session(conn, :user_id)
      assert user_id

      user = Accounts.get_user!(user_id)
      assert user.email == email
      # Email is pre-verified for GitHub users
      refute is_nil(user.email_verified_at)

      # oauth_identities row exists
      identity =
        Fountain.Repo.get_by(Fountain.Accounts.OauthIdentity,
          user_id: user.id,
          provider: "github"
        )

      assert identity
      assert identity.provider_uid == to_string(auth.uid)
    end
  end

  describe "callback/2 — success (existing user)" do
    test "logs in existing user and redirects to conversations", %{conn: conn} do
      user = insert_verified_user()
      auth = github_auth(user.email, "gh_existing_#{System.unique_integer()}")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_auth(auth)
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/conversations"
      assert get_session(conn, :user_id) == user.id
    end
  end

  describe "callback/2 — failure" do
    test "redirects to login with error flash on OAuth failure", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_failure(github_failure())
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "uses fallback message when failure has no errors", %{conn: conn} do
      failure = %Ueberauth.Failure{
        provider: :github,
        strategy: Ueberauth.Strategy.Github,
        errors: []
      }

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_failure(failure)
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "redirects to login when GitHub returns no email", %{conn: conn} do
      auth = %{github_auth("") | info: %Ueberauth.Auth.Info{email: nil}}

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_auth(auth)
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "redirects to login when GitHub returns an empty-string email", %{conn: conn} do
      auth = github_auth("")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_auth(auth)
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/auth/login"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "GitHub did not return a verified email address."
    end
  end

  describe "callback/2 — upsert_oauth_user error" do
    test "redirects to login with error flash when upsert_oauth_user returns an error", %{conn: conn} do
      email = "github_error_#{System.unique_integer()}@example.com"
      auth = github_auth(email)

      stub(Accounts, :upsert_oauth_user, fn _provider, _uid, _attrs ->
        changeset =
          %Fountain.Accounts.User{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:email, "simulated failure")
        {:error, changeset}
      end)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> assign_auth(auth)
        |> get(~p"/auth/oauth/github/callback")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not sign in"
    end
  end

  describe "request/2 — unknown provider fallback" do
    test "redirects to login with error flash when provider is not configured", %{conn: conn} do
      # In ueberauth_test_mode the Ueberauth plug is skipped, so request/2
      # fires directly for any GET /auth/oauth/:provider request.
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> get(~p"/auth/oauth/github")

      assert redirected_to(conn) == ~p"/auth/login"
    end
  end
end
