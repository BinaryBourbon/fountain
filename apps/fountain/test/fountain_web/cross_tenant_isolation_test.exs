defmodule FountainWeb.CrossTenantIsolationTest do
  @moduledoc """
  Regression tests for the multi-tenant isolation work in PRs #44, #48–#52,
  and #54. Every scoped endpoint should return 404 when user B tries to
  read or write user A's resources.

  If you add a new resource controller, add a corresponding case here.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.{Crypto, Vaults}

  # ── helpers ────────────────────────────────────────────────────────────────

  defp two_users do
    user_a = insert_verified_user()
    user_b = insert_verified_user()
    {_, key_a} = insert_api_key(user_a)
    {_, key_b} = insert_api_key(user_b)
    {user_a, user_b, key_a, key_b}
  end

  # ── Conversations ──────────────────────────────────────────────────────────

  describe "conversations" do
    test "GET /api/conversations returns only the caller's conversations", %{conn: conn} do
      {user_a, _user_b, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)
      conv_a = insert_conversation(user_id: user_a.id, agent: agent_a)

      resp =
        conn
        |> authed_with_key(key_b)
        |> get("/api/conversations")
        |> json_response(200)

      assert resp["data"] |> Enum.map(& &1["id"]) |> Enum.member?(conv_a.id) == false
    end

    test "GET /api/conversations/:id returns 404 for another user's conversation", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)
      conv_a = insert_conversation(user_id: user_a.id, agent: agent_a)

      conn
      |> authed_with_key(key_b)
      |> get("/api/conversations/#{conv_a.id}")
      |> json_response(404)
    end

    test "DELETE /api/conversations/:id returns 404 and does not delete", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)
      conv_a = insert_conversation(user_id: user_a.id, agent: agent_a)

      conn
      |> authed_with_key(key_b)
      |> delete("/api/conversations/#{conv_a.id}")
      |> json_response(404)

      assert Fountain.Repo.get(Fountain.Conversations.Conversation, conv_a.id) != nil
    end
  end

  # ── Agents ─────────────────────────────────────────────────────────────────

  describe "agents" do
    test "GET /api/agents returns only the caller's agents", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)

      resp =
        conn
        |> authed_with_key(key_b)
        |> get("/api/agents")
        |> json_response(200)

      assert resp["data"] |> Enum.map(& &1["id"]) |> Enum.member?(agent_a.id) == false
    end

    test "GET /api/agents/:id returns 404 for another user's agent", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> get("/api/agents/#{agent_a.id}")
      |> json_response(404)
    end

    test "POST /api/agents ignores spoofed user_id in the body", %{conn: conn} do
      {user_a, user_b, _, key_b} = two_users()

      resp =
        conn
        |> authed_with_key(key_b)
        |> post_json("/api/agents", %{
          "name" => "spoof-agent",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude",
          "user_id" => user_a.id
        })
        |> json_response(201)

      agent = Fountain.Repo.get(Fountain.Agents.Agent, resp["data"]["id"])
      assert agent.user_id == user_b.id
    end

    test "PATCH /api/agents/:id ignores user_id in the body (no owner reassignment)",
         %{conn: conn} do
      {user_a, user_b, _, key_b} = two_users()
      agent_b = insert_agent(user_id: user_b.id)

      conn
      |> authed_with_key(key_b)
      |> put_json("/api/agents/#{agent_b.id}", %{"name" => "renamed", "user_id" => user_a.id})
      |> json_response(200)

      reloaded = Fountain.Repo.get(Fountain.Agents.Agent, agent_b.id)
      assert reloaded.user_id == user_b.id
      assert reloaded.name == "renamed"
    end

    test "DELETE /api/agents/:id returns 404 and does not delete", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> delete("/api/agents/#{agent_a.id}")
      |> json_response(404)

      assert Fountain.Repo.get(Fountain.Agents.Agent, agent_a.id) != nil
    end
  end

  # ── Environments ───────────────────────────────────────────────────────────

  describe "environments" do
    test "GET /api/environments returns only the caller's envs", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      env_a = insert_env(user_id: user_a.id)

      resp =
        conn
        |> authed_with_key(key_b)
        |> get("/api/environments")
        |> json_response(200)

      assert resp["data"] |> Enum.map(& &1["id"]) |> Enum.member?(env_a.id) == false
    end

    test "GET /api/environments/:id returns 404 for another user's env", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      env_a = insert_env(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> get("/api/environments/#{env_a.id}")
      |> json_response(404)
    end

    test "DELETE /api/environments/:id returns 404 and does not delete", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      env_a = insert_env(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> delete("/api/environments/#{env_a.id}")
      |> json_response(404)

      assert Fountain.Repo.get(Fountain.Environments.Environment, env_a.id) != nil
    end

    test "POST /api/environments/:env_id/secrets returns 404 against another user's env",
         %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      env_a = insert_env(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> post_json("/api/environments/#{env_a.id}/secrets", %{
        "key" => "INJECTED_KEY",
        "value" => "leak"
      })
      |> json_response(404)

      assert Fountain.Environments.list_secrets(env_a) == []
    end
  end

  # ── Vaults ─────────────────────────────────────────────────────────────────

  describe "vaults" do
    test "GET /api/vaults returns only the caller's vaults", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      vault_a = insert_vault(user_id: user_a.id)

      resp =
        conn
        |> authed_with_key(key_b)
        |> get("/api/vaults")
        |> json_response(200)

      assert resp["data"] |> Enum.map(& &1["id"]) |> Enum.member?(vault_a.id) == false
    end

    test "GET /api/vaults/:id returns 404 for another user's vault", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      vault_a = insert_vault(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> get("/api/vaults/#{vault_a.id}")
      |> json_response(404)
    end

    test "POST /api/vaults/:vault_id/secrets returns 404 against another user's vault",
         %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      vault_a = insert_vault(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> post_json("/api/vaults/#{vault_a.id}/secrets", %{
        "key" => "INJECTED_KEY",
        "value" => "leak"
      })
      |> json_response(404)

      assert Vaults.list_secrets(vault_a) == []
    end

    test "DELETE /api/vaults/:vault_id/secrets/:id returns 404 and does not delete",
         %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      vault_a = insert_vault(user_id: user_a.id)
      secret = insert_vault_secret(vault_a, %{"key" => "KEEP_ME"})

      conn
      |> authed_with_key(key_b)
      |> delete("/api/vaults/#{vault_a.id}/secrets/#{secret.key}")
      |> json_response(404)

      {:ok, dek} = Crypto.load_tenant_key(user_a.id)
      assert Vaults.decrypted_env(vault_a, dek) |> Map.has_key?("KEEP_ME")
    end

    test "POST /api/conversations rejects another user's vault_id", %{conn: conn} do
      {user_a, user_b, _, key_b} = two_users()
      vault_a = insert_vault(user_id: user_a.id)
      agent_b = insert_agent(user_id: user_b.id)

      conn
      |> authed_with_key(key_b)
      |> post_json("/api/conversations", %{
        "agent_id" => agent_b.id,
        "vault_id" => vault_a.id
      })
      |> json_response(404)
    end

    test "POST /api/conversations rejects another user's agent_id", %{conn: conn} do
      {user_a, _, _, key_b} = two_users()
      agent_a = insert_agent(user_id: user_a.id)

      conn
      |> authed_with_key(key_b)
      |> post_json("/api/conversations", %{"agent_id" => agent_a.id})
      |> json_response(404)
    end
  end
end
