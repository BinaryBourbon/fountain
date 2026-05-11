defmodule FountainWeb.EnvironmentControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/environments" do
    test "returns 200 and lists user's environments", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert env.id in ids
    end

    test "does not include environments belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_env.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/environments")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/environments/:id" do
    test "returns 200 with the environment for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments/#{env.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == env.id
      assert body["data"]["name"] == env.name
    end

    test "returns 404 when the environment belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments/#{other_env.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = get(conn, "/api/environments/#{env.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/environments" do
    test "creates an environment and returns 201", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "my-env"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/environments", payload)

      body = json_response(conn, 201)
      assert body["data"]["name"] == "my-env"
      assert body["data"]["id"]
    end

    test "returns 401 without authentication", %{conn: conn} do
      payload = %{name: "my-env"}
      conn = post_json(conn, "/api/environments", payload)
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/environments/:id" do
    test "updates the environment and returns 200", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{env.id}", %{name: "updated-env"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "updated-env"
      assert body["data"]["id"] == env.id
    end

    test "returns 404 when the environment belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{other_env.id}", %{name: "hacked"})

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = put_json(conn, "/api/environments/#{env.id}", %{name: "updated"})
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/environments/:id" do
    test "deletes the environment and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/environments/#{env.id}")

      assert conn.status == 204
    end

    test "returns 404 when the environment belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/environments/#{other_env.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = delete(conn, "/api/environments/#{env.id}")
      assert json_response(conn, 401)
    end
  end
end
