defmodule FountainWeb.SecretControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/environments/:environment_id/secrets" do
    test "returns 200 with a list of secrets for the environment", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)
      secret = insert_secret(env, key: "MY_KEY")

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments/#{env.id}/secrets")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      keys = Enum.map(body["data"], & &1["key"])
      assert secret.key in keys
    end

    test "returns 404 when environment belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments/#{other_env.id}/secrets")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = get(conn, "/api/environments/#{env.id}/secrets")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/environments/:environment_id/secrets" do
    test "creates a secret and returns 201", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/environments/#{env.id}/secrets", %{key: "DB_PASSWORD", value: "s3cr3t"})

      body = json_response(conn, 201)
      assert body["data"]["key"] == "DB_PASSWORD"
      refute Map.has_key?(body["data"], "value")
    end

    test "returns 404 when environment belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/environments/#{other_env.id}/secrets", %{key: "DB_PASSWORD", value: "s3cr3t"})

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/environments/:environment_id/secrets/:id" do
    test "deletes a secret by key and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)
      secret = insert_secret(env, key: "TO_DELETE")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/environments/#{env.id}/secrets/#{secret.key}")

      assert conn.status == 204
    end

    test "returns 404 when environment belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)
      other_secret = insert_secret(other_env, key: "OTHER_KEY")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/environments/#{other_env.id}/secrets/#{other_secret.key}")

      assert json_response(conn, 404)
    end

    test "returns 404 when the secret key does not exist", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/environments/#{env.id}/secrets/NONEXISTENT_KEY")

      assert json_response(conn, 404)
    end
  end
end
