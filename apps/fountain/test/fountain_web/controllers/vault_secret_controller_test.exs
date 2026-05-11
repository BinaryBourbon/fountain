defmodule FountainWeb.VaultSecretControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/vaults/:vault_id/secrets" do
    test "returns 200 with a list of secrets for the vault", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "MY_KEY")

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{vault.id}/secrets")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      keys = Enum.map(body["data"], & &1["key"])
      assert secret.key in keys
    end

    test "returns 404 when vault belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{other_vault.id}/secrets")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/vaults/:vault_id/secrets" do
    test "creates a vault secret and returns 201", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{vault.id}/secrets", %{key: "API_TOKEN", value: "t0k3n"})

      body = json_response(conn, 201)
      assert body["data"]["key"] == "API_TOKEN"
      refute Map.has_key?(body["data"], "value")
    end

    test "returns 404 when vault belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{other_vault.id}/secrets", %{key: "API_TOKEN", value: "t0k3n"})

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/vaults/:vault_id/secrets/:id" do
    test "deletes a vault secret by key and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TO_DELETE")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/vaults/#{vault.id}/secrets/#{secret.key}")

      assert conn.status == 204
    end

    test "returns 404 when vault belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)
      other_secret = insert_vault_secret(other_vault, key: "OTHER_KEY")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/vaults/#{other_vault.id}/secrets/#{other_secret.key}")

      assert json_response(conn, 404)
    end

    test "returns 404 when the secret key does not exist", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/vaults/#{vault.id}/secrets/NONEXISTENT_KEY")

      assert json_response(conn, 404)
    end
  end
end
