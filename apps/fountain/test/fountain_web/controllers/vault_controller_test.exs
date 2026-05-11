defmodule FountainWeb.VaultControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/vaults" do
    test "returns 200 and lists user's vaults", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert vault.id in ids
    end

    test "does not include vaults belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_vault.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/vaults")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/vaults/:id" do
    test "returns 200 with the vault for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{vault.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == vault.id
      assert body["data"]["name"] == vault.name
    end

    test "returns 404 when the vault belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{other_vault.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      conn = get(conn, "/api/vaults/#{vault.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/vaults" do
    test "creates a vault and returns 201", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "my-vault"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults", payload)

      body = json_response(conn, 201)
      assert body["data"]["name"] == "my-vault"
      assert body["data"]["id"]
    end

    test "returns 401 without authentication", %{conn: conn} do
      payload = %{name: "my-vault"}
      conn = post_json(conn, "/api/vaults", payload)
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/vaults/:id" do
    test "updates the vault and returns 200", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/vaults/#{vault.id}", %{name: "updated-vault"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "updated-vault"
      assert body["data"]["id"] == vault.id
    end

    test "returns 404 when the vault belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/vaults/#{other_vault.id}", %{name: "hacked"})

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      conn = put_json(conn, "/api/vaults/#{vault.id}", %{name: "updated"})
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/vaults/:id" do
    test "deletes the vault and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/vaults/#{vault.id}")

      assert conn.status == 204
    end

    test "returns 404 when the vault belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/vaults/#{other_vault.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      conn = delete(conn, "/api/vaults/#{vault.id}")
      assert json_response(conn, 401)
    end
  end
end
