defmodule FountainWeb.ApplyControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.{Agents, Crypto, Environments, Vaults}

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "POST /api/apply" do
    test "applies a full manifest in one request", %{conn: conn, user: user, raw_key: raw_key} do
      payload = %{
        "resources" => [
          %{
            "kind" => "Environment",
            "name" => "proj",
            "spec" => %{"setup_script" => "echo hi", "secrets" => %{"TOKEN" => "t0"}}
          },
          %{
            "kind" => "Vault",
            "name" => "alice",
            "spec" => %{"secrets" => %{"GH" => "ghp_x"}}
          },
          %{
            "kind" => "Agent",
            "name" => "researcher",
            "spec" => %{
              "model" => "anthropic/claude-sonnet-4-6",
              "runtime" => "claude",
              "environment" => "proj"
            }
          }
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => results}} = json_response(conn, 200)

      assert [
               %{
                 "kind" => "Environment",
                 "name" => "proj",
                 "action" => "created",
                 "errors" => nil,
                 "secrets" => [%{"key" => "TOKEN", "action" => "upserted"}]
               },
               %{"kind" => "Vault", "name" => "alice", "action" => "created"},
               %{"kind" => "Agent", "name" => "researcher", "action" => "created"}
             ] = results

      env = Environments.get_environment_by_name("proj", user.id)
      assert env.setup_script == "echo hi"
      assert Agents.get_agent_by_name("researcher", user.id).environment_id == env.id

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "t0"}

      assert Vaults.decrypted_env(Vaults.get_vault_by_name("alice", user.id), dek) == %{
               "GH" => "ghp_x"
             }
    end

    test "never echoes secret values back", %{conn: conn, raw_key: raw_key} do
      payload = %{
        "resources" => [
          %{"kind" => "Vault", "name" => "v", "spec" => %{"secrets" => %{"GH" => "sekrit-value"}}}
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert json_response(conn, 200)
      refute conn.resp_body =~ "sekrit-value"
    end

    test "re-apply reports updated actions", %{conn: conn, raw_key: raw_key} do
      payload = %{
        "resources" => [%{"kind" => "Vault", "name" => "v", "spec" => %{}}]
      }

      auth = fn conn -> authed_with_key(conn, raw_key) end

      assert %{"data" => %{"results" => [%{"action" => "created"}]}} =
               conn |> auth.() |> post_json(~p"/api/apply", payload) |> json_response(200)

      assert %{"data" => %{"results" => [%{"action" => "updated"}]}} =
               build_conn() |> auth.() |> post_json(~p"/api/apply", payload) |> json_response(200)
    end

    test "returns 200 with per-resource errors on partial failure", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      payload = %{
        "resources" => [
          %{"kind" => "Vault", "name" => "ok", "spec" => %{}},
          %{"kind" => "Agent", "name" => "broken", "spec" => %{"runtime" => "claude"}}
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => [vault_result, agent_result]}} = json_response(conn, 200)
      assert vault_result["action"] == "created"
      assert agent_result["action"] == "error"
      assert %{"model" => _} = agent_result["errors"]
      assert Vaults.get_vault_by_name("ok", user.id)
      refute Agents.get_agent_by_name("broken", user.id)
    end

    test "rejects an invalid kind with 422", %{conn: conn, raw_key: raw_key} do
      payload = %{"resources" => [%{"kind" => "Cluster", "name" => "x", "spec" => %{}}]}

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)
      assert conn.status == 422
    end

    test "rejects a payload without resources with 422", %{conn: conn, raw_key: raw_key} do
      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", %{})
      assert conn.status == 422
    end

    test "requires authentication", %{conn: conn} do
      conn = post_json(conn, ~p"/api/apply", %{"resources" => []})
      assert conn.status == 401
    end
  end
end
