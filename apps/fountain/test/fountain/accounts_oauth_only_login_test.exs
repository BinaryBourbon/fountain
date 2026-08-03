defmodule Fountain.AccountsOauthOnlyLoginTest do
  # #324: authenticate_user/2 called Bcrypt.verify_pass on a nil
  # password_hash for OAuth-only accounts — an ArgumentError, so
  # POST /auth/login and POST /api/auth/token answered 500 for exactly the
  # emails that have an OAuth-only account: a crash and an
  # account-existence oracle in one.
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.User

  defp insert_oauth_only_user do
    %User{}
    |> User.oauth_registration_changeset(%{
      email: "oauthonly-#{System.unique_integer([:positive])}@example.com",
      email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  test "a password attempt against an OAuth-only account fails like any wrong password" do
    user = insert_oauth_only_user()
    assert is_nil(user.password_hash)

    assert {:error, :wrong_password} = Accounts.authenticate_user(user.email, "any-password")
  end

  test "password accounts still authenticate" do
    user = insert_verified_user()
    assert {:ok, %User{}} = Accounts.authenticate_user(user.email, "password123")
  end
end

defmodule FountainWeb.OauthOnlyLoginControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Accounts.User

  defp insert_oauth_only_user do
    %User{}
    |> User.oauth_registration_changeset(%{
      email: "oauthonly-#{System.unique_integer([:positive])}@example.com",
      email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Fountain.Repo.insert!()
  end

  test "POST /auth/login answers the standard 401, not a 500", %{conn: conn} do
    user = insert_oauth_only_user()

    conn = post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "x"})

    body = html_response(conn, 401)
    assert body =~ "Invalid email or password"
  end

  test "POST /api/auth/token answers the standard 401, not a 500", %{conn: conn} do
    user = insert_oauth_only_user()

    conn = post_json(conn, ~p"/api/auth/token", %{email: user.email, password: "x"})

    assert conn.status == 401
    # Same body an unknown email gets — no oracle.
    assert %{"error" => _} = json_response(conn, 401)
  end
end
