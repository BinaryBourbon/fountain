defmodule FountainWeb.AuthMeControllerTest do
  # async: false for the billing-disabled tests, which flip global app env.
  use FountainWeb.ConnCase, async: false

  defp with_billing_disabled(fun) do
    previous = Application.get_env(:fountain, :billing_enabled)
    Application.put_env(:fountain, :billing_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:fountain, :billing_enabled, previous)
    end
  end

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
               "comped" => comped
             } = json_response(conn, 200)

      assert id == user.id
      assert email == user.email
      assert role == user.role
      assert comped == false
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

    test "comped is null when billing is disabled — key kept for shape compat (#480)",
         %{conn: conn} do
      # Residue case on purpose: even an account that still carries a status
      # from before the flag flipped must not leak it to API consumers.
      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)

      with_billing_disabled(fn ->
        conn =
          conn
          |> authed_with_key(raw_key)
          |> get("/api/auth/me")

        body = json_response(conn, 200)
        assert Map.has_key?(body, "comped")
        assert body["comped"] == nil
      end)
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
