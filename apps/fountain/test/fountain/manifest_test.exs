defmodule Fountain.ManifestTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Agents, Crypto, Environments, Manifest, Vaults}

  setup do
    %{user: insert_verified_user()}
  end

  defp env_resource(name, spec \\ %{}) do
    %{"kind" => "Environment", "name" => name, "spec" => spec}
  end

  defp vault_resource(name, spec \\ %{}) do
    %{"kind" => "Vault", "name" => name, "spec" => spec}
  end

  defp agent_resource(name, spec \\ %{}) do
    spec =
      Map.merge(%{"model" => "anthropic/claude-sonnet-4-6", "runtime" => "claude"}, spec)

    %{"kind" => "Agent", "name" => name, "spec" => spec}
  end

  describe "apply_manifest/2 creation" do
    test "creates environments, vaults, and agents with secrets", %{user: user} do
      resources = [
        agent_resource("researcher", %{"environment" => "proj"}),
        vault_resource("alice", %{"secrets" => %{"GH" => "ghp_x", "NPM" => "npm_y"}}),
        env_resource("proj", %{
          "setup_script" => "echo hi",
          "secrets" => %{"TOKEN" => "t0"}
        })
      ]

      {:ok, results} = Manifest.apply_manifest(user.id, resources)

      # Reconciliation order is envs, vaults, agents regardless of input order.
      assert [
               %{kind: "Environment", name: "proj", action: :created, secrets: [env_secret]},
               %{kind: "Vault", name: "alice", action: :created, secrets: vault_secrets},
               %{kind: "Agent", name: "researcher", action: :created}
             ] = results

      assert env_secret == %{key: "TOKEN", action: :upserted, errors: nil}
      assert Enum.map(vault_secrets, & &1.key) == ["GH", "NPM"]

      env = Environments.get_environment_by_name("proj", user.id)
      assert env.setup_script == "echo hi"

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "t0"}

      vault = Vaults.get_vault_by_name("alice", user.id)
      assert Vaults.decrypted_env(vault, dek) == %{"GH" => "ghp_x", "NPM" => "npm_y"}

      agent = Agents.get_agent_by_name("researcher", user.id)
      assert agent.environment_id == env.id
    end

    test "coerces numeric and boolean secret values to strings", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          vault_resource("v", %{"secrets" => %{"PORT" => 5432, "DEBUG" => true}})
        ])

      assert [%{action: :created, secrets: secrets}] = results
      assert Enum.all?(secrets, &(&1.action == :upserted))

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      vault = Vaults.get_vault_by_name("v", user.id)
      assert Vaults.decrypted_env(vault, dek) == %{"PORT" => "5432", "DEBUG" => "true"}
    end
  end

  describe "apply_manifest/2 updates" do
    test "re-applying the same manifest is an idempotent update", %{user: user} do
      resources = [
        env_resource("proj", %{"secrets" => %{"TOKEN" => "t0"}}),
        agent_resource("researcher", %{"environment" => "proj"})
      ]

      {:ok, _} = Manifest.apply_manifest(user.id, resources)
      {:ok, results} = Manifest.apply_manifest(user.id, resources)

      assert [
               %{kind: "Environment", action: :updated, secrets: [%{action: :upserted}]},
               %{kind: "Agent", action: :updated}
             ] = results

      assert length(Environments.list_environments(user.id)) == 1
      assert length(Agents.list_agents(user.id, [])) == 1
    end

    test "agent can reference a pre-existing environment not in the manifest", %{user: user} do
      env = insert_env(user_id: user.id, name: "existing-env")

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          agent_resource("a", %{"environment" => "existing-env"})
        ])

      assert [%{kind: "Agent", action: :created, errors: nil}] = results
      assert Agents.get_agent_by_name("a", user.id).environment_id == env.id
    end
  end

  describe "apply_manifest/2 errors" do
    test "unknown environment reference fails that agent only", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          vault_resource("v"),
          agent_resource("a", %{"environment" => "nope"})
        ])

      assert [
               %{kind: "Vault", action: :created},
               %{kind: "Agent", name: "a", action: :error, errors: errors}
             ] = results

      assert errors == %{"environment" => ["environment not found: nope"]}
      assert Agents.get_agent_by_name("a", user.id) == nil
    end

    test "a failing resource does not stop the rest of the manifest", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          %{"kind" => "Agent", "name" => "broken", "spec" => %{"runtime" => "claude"}},
          agent_resource("ok-agent")
        ])

      assert [
               %{name: "broken", action: :error, errors: %{model: _}},
               %{name: "ok-agent", action: :created}
             ] = results
    end

    test "malformed resources are reported, not applied", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          %{"kind" => "Cluster", "name" => "x"},
          %{"kind" => "Vault", "name" => ""},
          vault_resource("good")
        ])

      assert [
               %{kind: "Vault", name: "good", action: :created},
               %{kind: "Cluster", name: "x", action: :error},
               %{kind: "Vault", name: "", action: :error}
             ] = results

      assert Vaults.list_vaults(user.id) |> length() == 1
    end

    test "manifest specs cannot reassign ownership", %{user: user} do
      other = insert_verified_user()

      {:ok, [%{action: :created}]} =
        Manifest.apply_manifest(user.id, [
          vault_resource("mine", %{"user_id" => other.id, "id" => Ecto.UUID.generate()})
        ])

      assert [vault] = Vaults.list_vaults(user.id)
      assert vault.user_id == user.id
      assert Vaults.list_vaults(other.id) == []
    end
  end

  describe "apply_manifest/2 tenant isolation" do
    test "same-named resources of another tenant are not touched", %{user: user} do
      other = insert_verified_user()
      other_env = insert_env(user_id: other.id, name: "shared-name", setup_script: "original")

      {:ok, [%{kind: "Environment", action: :created}]} =
        Manifest.apply_manifest(user.id, [
          env_resource("shared-name", %{"setup_script" => "mine"})
        ])

      assert Environments.get_environment_by_name("shared-name", user.id).setup_script == "mine"
      assert Environments.get_environment!(other_env.id, other.id).setup_script == "original"
    end

    test "agent environment references cannot resolve to another tenant's environment",
         %{user: user} do
      other = insert_verified_user()
      insert_env(user_id: other.id, name: "their-env")

      {:ok, [%{kind: "Agent", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [
          agent_resource("a", %{"environment" => "their-env"})
        ])

      assert errors == %{"environment" => ["environment not found: their-env"]}
    end
  end
end
