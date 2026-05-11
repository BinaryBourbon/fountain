defmodule FountainWeb.PasswordResetControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Accounts

  describe "GET /auth/forgot-password" do
    test "renders the forgot password form", %{conn: conn} do
      conn = get(conn, ~p"/auth/forgot-password")
      assert html_response(conn, 200) =~ "reset"
    end
  end

  describe "POST /api/auth/forgot" do
    test "always returns 200 regardless of whether email exists", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{email: "nobody@example.com"}))

      assert json_response(conn, 200)["message"] =~ "registered"
    end

    test "returns 200 for a real user too (no enumeration)", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{email: user.email}))

      assert json_response(conn, 200)["message"] =~ "registered"
    end

    test "returns 200 even with no email param", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{}))

      assert json_response(conn, 200)
    end
  end

  describe "GET /auth/reset/:token" do
    test "renders reset form for valid token", %{conn: conn} do
      user = insert_verified_user()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", user.id)

      conn = get(conn, ~p"/auth/reset/#{token}")
      assert html_response(conn, 200) =~ "new password"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/auth/reset/badtoken")
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "redirects with error when reset token has expired", %{conn: conn} do
      user = insert_verified_user()
      expired_token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", user.id, signed_at: 0)

      conn = get(conn, ~p"/auth/reset/#{expired_token}")
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end
  end

  describe "POST /auth/reset" do
    test "updates password and drops session", %{conn: conn} do
      user = insert_verified_user()
      old_hash = Accounts.get_user!(user.id).password_hash
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", user.id)

      conn = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "newpassword123"})
      assert redirected_to(conn) == ~p"/auth/login"

      updated = Accounts.get_user!(user.id)
      refute updated.password_hash == old_hash
      # session_version bumped — old sessions invalidated
      assert updated.session_version > user.session_version
    end

    test "re-renders form with error on short password", %{conn: conn} do
      user = insert_verified_user()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", user.id)

      conn = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "short"})
      assert html_response(conn, 422) =~ "new password"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn = post(conn, ~p"/auth/reset", %{"token" => "badtoken", "password" => "validpassword123"})
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "redirects with error when user no longer exists in database", %{conn: conn} do
      # Sign a token with a UUID that doesn't correspond to any user
      missing_id = Ecto.UUID.generate()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", missing_id)

      conn = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "validpassword123"})
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "redirects with error when reset token has expired", %{conn: conn} do
      user = insert_verified_user()
      expired_token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", user.id, signed_at: 0)

      conn = post(conn, ~p"/auth/reset", %{"token" => expired_token, "password" => "newpassword123"})
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end
  end
end
