defmodule FountainWeb.FallbackControllerTest do
  @moduledoc """
  Tests for FallbackController error clauses, exercised through AgentController
  which declares `action_fallback FountainWeb.FallbackController`.
  """
  use FountainWeb.ConnCase, async: true

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
