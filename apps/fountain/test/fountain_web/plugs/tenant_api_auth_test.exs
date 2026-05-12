defmodule FountainWeb.Plugs.TenantAPIAuthTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.Plugs.TenantAPIAuth

  describe "call/2" do
    test "sets current_user when valid Bearer key is provided", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "returns 401 when no Authorization header", %{conn: conn} do
      conn = TenantAPIAuth.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "missing"
      assert body["reason"] == "api_key_invalid"
    end

    test "returns 401 for malformed Authorization header", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "NotBearer token")
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["reason"] == "api_key_invalid"
    end

    test "returns 401 with api_key_invalid for unknown key", %{conn: conn} do
      conn =
        conn
        |> authed_with_key("ftn_" <> String.duplicate("0", 64))
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["reason"] == "api_key_invalid"
    end

    test "returns 401 with api_key_revoked for revoked key", %{conn: conn} do
      user = insert_verified_user()
      {record, raw_key} = insert_api_key(user)
      {:ok, _} = Fountain.Accounts.revoke_api_key(user.id, record.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> TenantAPIAuth.call([])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "revoked"
      assert body["reason"] == "api_key_revoked"
    end

    test "cross-tenant key does not authenticate another user", %{conn: conn} do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      {_record, raw_key_a} = insert_api_key(user_a)

      conn =
        conn
        |> authed_with_key(raw_key_a)
        |> TenantAPIAuth.call([])

      refute conn.halted
      # user_a's key does not return user_b
      refute conn.assigns.current_user.id == user_b.id
    end
  end
end
