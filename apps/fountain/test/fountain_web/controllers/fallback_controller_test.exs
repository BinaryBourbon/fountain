defmodule FountainWeb.FallbackControllerTest do
  @moduledoc """
  Tests for FallbackController error clauses, exercised through AgentController
  which declares `action_fallback FountainWeb.FallbackController`.
  """
  use FountainWeb.ConnCase, async: true

  test "an uncertain reset reports an explicit conflict", %{conn: conn} do
    conn = FountainWeb.FallbackController.call(conn, {:error, :sandbox_reset_pending})
    assert %{"error" => "sandbox_reset_pending"} = json_response(conn, 409)
  end

  # Driven directly rather than through the route: reaching this refusal needs
  # an agent on the runner provider, and `runners_enabled` is global
  # application env this async module must not write (#1214). The `message` is
  # the assertion that matters — the terminal safety net answers 422 with the
  # bare atom, so a status-only check would pass with no clause at all (#1632).
  test "a sprite_name on the runner provider is refused with a reason", %{conn: conn} do
    conn = FountainWeb.FallbackController.call(conn, {:error, :sprite_name_not_supported})
    body = json_response(conn, 422)
    assert body["error"] == "sprite_name_not_supported"
    assert body["message"] =~ "self-hosted runner"
  end

  test "unusable opening input names itself rather than falling to the safety net", %{conn: conn} do
    for {reason, error} <- [invalid_prompt: "invalid_prompt", invalid_images: "invalid_images"] do
      body =
        conn
        |> FountainWeb.FallbackController.call({:error, reason})
        |> json_response(422)

      assert body["error"] == error
      assert is_binary(body["message"]) and body["message"] != ""
    end
  end

  describe "{:error, %Ecto.Changeset{}} → 422" do
    test "POST /api/agents with missing required fields returns 422 with errors body", %{
      conn: conn
    } do
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

  describe "{:error, :sprite_probe_failed} → 503 (#799)" do
    test "a wake that could not reach the sandbox provider is retryable, not a 422", %{
      conn: conn
    } do
      conn = FountainWeb.FallbackController.call(conn, {:error, :sprite_probe_failed})
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["10"]
      assert %{"error" => "sandbox_probe_failed"} = Jason.decode!(conn.resp_body)
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
