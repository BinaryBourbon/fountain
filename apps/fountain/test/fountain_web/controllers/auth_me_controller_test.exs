defmodule FountainWeb.AuthMeControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /api/auth/me" do
    test "returns user identity for an authenticated request", %{conn: conn} do
      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{
               "id" => id,
               "email" => email,
               "role" => role,
               "subscription_status" => subscription_status
             } = json_response(conn, 200)

      assert id == user.id
      assert email == user.email
      assert role == user.role
      assert subscription_status == user.subscription_status
    end

    test "returns 401 when no API key is provided", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert conn.status == 401
    end

    test "returns 401 when an invalid API key is provided", %{conn: conn} do
      conn =
        conn
        |> authed_with_key("ftn_invalid000000000000000000000000000000000000000000000000000000")
        |> get("/api/auth/me")

      assert conn.status == 401
    end

    test "returns role field for an admin user", %{conn: conn} do
      user = insert_verified_user(%{"role" => "admin"})
      {_key_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{"role" => "admin"} = json_response(conn, 200)
    end

    test "email in response is downcased", %{conn: conn} do
      # registration downcases email; confirm the stored value is returned
      user = insert_verified_user(%{"email" => "MixedCase@Example.com"})
      {_key_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{"email" => email} = json_response(conn, 200)
      assert email == String.downcase(email)
    end
  end
end
