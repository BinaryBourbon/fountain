defmodule FountainWeb.FallbackControllerTest do
  @moduledoc """
  Tests for FallbackController error clauses, exercised through AgentController
  which declares `action_fallback FountainWeb.FallbackController`.
  """
  use FountainWeb.ConnCase, async: true

  describe "{:error, %Ecto.Changeset{}} → 422" do
    test "POST /api/agents with missing required fields returns 422 with errors body", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", %{})

      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "{:error, :vault_not_found} → 404" do
    test "POST /api/conversations with nonexistent vault_id returns 404", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          agent_id: agent.id,
          vault_id: Ecto.UUID.generate()
        })

      assert %{"error" => "vault_not_found"} = json_response(conn, 404)
    end
  end

  describe "{:error, binary_reason} → 400" do
    test "binary error reason returns 400 with error body", %{conn: conn} do
      conn = FountainWeb.FallbackController.call(conn, {:error, "custom_error_message"})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "custom_error_message"
    end
  end

  describe "{:error, :not_found} → 404" do
    test "GET /api/agents/:id with a nonexistent UUID returns 404 with error body", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/agents/#{Ecto.UUID.generate()}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "PUT /api/agents/:id with a nonexistent UUID returns 404", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{Ecto.UUID.generate()}", %{})

      assert json_response(conn, 404)
    end

    test "DELETE /api/agents/:id with a nonexistent UUID returns 404", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/agents/#{Ecto.UUID.generate()}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "a user cannot see another user's agent (cross-tenant isolation → 404)", %{conn: conn} do
      owner = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(%{"user_id" => owner.id})

      {_key, raw_key} = insert_api_key(other)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/agents/#{agent.id}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
