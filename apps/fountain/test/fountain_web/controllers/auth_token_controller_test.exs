defmodule FountainWeb.AuthTokenControllerTest do
  # async: false because the rate-limit ETS table is global state
  use FountainWeb.ConnCase, async: false

  describe "POST /api/auth/token" do
    test "returns 201 with api_key on valid credentials", %{conn: conn} do
      user = insert_verified_user(%{"email" => "login#{System.unique_integer()}@example.com", "password" => "password123"})

      conn = post_json(conn, "/api/auth/token", %{email: user.email, password: "password123"})

      assert %{"api_key" => key, "key_id" => _id, "prefix" => prefix} = json_response(conn, 201)
      assert is_binary(key)
      assert String.starts_with?(key, "ftn_")
      assert String.starts_with?(prefix, "ftn_")
    end

    test "returns 401 on wrong password", %{conn: conn} do
      user = insert_verified_user(%{"email" => "login#{System.unique_integer()}@example.com", "password" => "password123"})

      conn = post_json(conn, "/api/auth/token", %{email: user.email, password: "wrongpassword"})

      assert %{"error" => "Invalid email or password"} = json_response(conn, 401)
    end

    test "returns 401 on unknown email", %{conn: conn} do
      conn = post_json(conn, "/api/auth/token", %{email: "nobody@example.com", password: "password123"})

      assert %{"error" => "Invalid email or password"} = json_response(conn, 401)
    end

    test "api_key from response can authenticate GET /api/auth/me", %{conn: conn} do
      user = insert_verified_user(%{"email" => "login#{System.unique_integer()}@example.com", "password" => "password123"})

      %{"api_key" => raw_key} =
        conn
        |> post_json("/api/auth/token", %{email: user.email, password: "password123"})
        |> json_response(201)

      me_conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{"email" => email} = json_response(me_conn, 200)
      assert email == user.email
    end

    test "returns 422 when email or password missing", %{conn: conn} do
      conn = post_json(conn, "/api/auth/token", %{email: "only@example.com"})
      assert json_response(conn, 422)
    end
  end

  describe "rate limiting" do
    test "blocks 11th attempt from same IP within the hour", %{conn: conn} do
      for _ <- 1..10 do
        post_json(conn, "/api/auth/token", %{email: "x@example.com", password: "wrong"})
      end

      conn11 = post_json(conn, "/api/auth/token", %{email: "x@example.com", password: "wrong"})
      assert conn11.status == 429
    end
  end
end
