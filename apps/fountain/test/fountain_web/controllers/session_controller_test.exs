defmodule FountainWeb.SessionControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /login (legacy route removed, #327)" do
    test "no route exists for the legacy admin login", %{conn: conn} do
      assert get(conn, "/login").status == 404
      assert post(conn, "/login", %{token: "x"}).status == 404
      assert post(conn, "/logout").status == 404
    end
  end

  describe "POST /auth/login — suspended account (#287)" do
    test "refuses with a neutral message after a correct password", %{conn: conn} do
      user = insert_verified_user()
      {:ok, _, _} = Fountain.Accounts.suspend_user(user)

      conn =
        post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "password123"})

      body = html_response(conn, 401)
      assert body =~ "currently unavailable"
      refute body =~ "suspended"
    end

    test "wrong password on a suspended account looks like any bad login", %{conn: conn} do
      user = insert_verified_user()
      {:ok, _, _} = Fountain.Accounts.suspend_user(user)

      conn = post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "wrong"})

      body = html_response(conn, 401)
      assert body =~ "Invalid email or password"
      refute body =~ "unavailable"
    end
  end

end
