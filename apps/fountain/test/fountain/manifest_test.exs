defmodule Fountain.ManifestTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Agents, Audit, Crypto, Environments, Manifest, Vaults}

  setup do
    # No starter agent (ADR 0038): every assertion here counts what the
    # manifest reconciled, and an agent the account was given is not that.
    %{user: insert_user_without_agents()}
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

  describe "spec keys" do
    test "rejects unknown keys on each kind before it creates records", %{user: user} do
      resources = [
        env_resource("bad-env", %{
          "network_policy" => "limited",
          "allowed_hosts" => ["example.test"]
        }),
        vault_resource("bad-vault", %{"descrption" => "private"}),
        agent_resource("bad-agent", %{"permisson_policy" => %{"default" => "auto_deny"}}),
        vault_resource("good-vault")
      ]

      assert {:ok, [env, vault, good, agent]} = Manifest.apply_manifest(user.id, resources)
      assert env.action == :error
      assert Enum.sort(Map.keys(env.errors)) == ["allowed_hosts", "network_policy"]
      assert vault.action == :error
      assert Map.has_key?(vault.errors, "descrption")
      assert agent.action == :error
      assert Map.has_key?(agent.errors, "permisson_policy")
      assert good.action == :created
      refute Environments.get_environment_by_name("bad-env", user.id)
      refute Vaults.get_vault_by_name("bad-vault", user.id)
      refute Agents.get_agent_by_name("bad-agent", user.id)
    end

    test "a rejected update writes neither attributes nor secrets", %{user: user} do
      assert {:ok, [%{action: :created}]} =
               Manifest.apply_manifest(user.id, [
                 env_resource("locked", %{
                   "setup_script" => "original",
                   "networking_type" => "limited",
                   "networking_config" => %{"allowed_hosts" => ["example.test"]},
                   "secrets" => %{"TOKEN" => "original"}
                 })
               ])

      assert {:ok, [%{action: :error, secrets: []}]} =
               Manifest.apply_manifest(user.id, [
                 env_resource("locked", %{
                   "setup_script" => "changed",
                   "network_policy" => "unrestricted",
                   "secrets" => %{"TOKEN" => "replacement"}
                 })
               ])

      env = Environments.get_environment_by_name("locked", user.id)
      assert env.setup_script == "original"
      assert env.networking_type == "limited"
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "original"}
    end

    test "database fields and secrets on an Agent are not accepted spec keys", %{user: user} do
      for resource <- [
            env_resource("e", %{"inserted_at" => "2026-01-01T00:00:00Z"}),
            vault_resource("v", %{"secret_count" => 4}),
            agent_resource("a", %{"avatar_media_type" => "image/png", "secrets" => %{}})
          ] do
        assert {:ok, [%{action: :error}]} = Manifest.apply_manifest(user.id, [resource])
      end
    end
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

    # chant's fountain lexicon marks resources it manages with
    # metadata."managed-by" and prunes by reading that marker back from the
    # list endpoints — bulk apply must persist spec.metadata verbatim.
    test "spec.metadata (e.g. chant's managed-by marker) survives apply", %{user: user} do
      marker = %{"managed-by" => "chant"}

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          env_resource("e", %{"metadata" => marker}),
          vault_resource("v", %{"metadata" => marker}),
          agent_resource("a", %{"metadata" => marker})
        ])

      assert Enum.all?(results, &(&1.action == :created))
      assert Environments.get_environment_by_name("e", user.id).metadata == marker
      assert Vaults.get_vault_by_name("v", user.id).metadata == marker
      assert Agents.get_agent_by_name("a", user.id).metadata == marker
    end
  end

  describe "apply_manifest/2 updates" do
    test "re-applying the same manifest writes nothing and says so", %{user: user} do
      resources = [
        env_resource("proj", %{"secrets" => %{"TOKEN" => "t0"}}),
        agent_resource("researcher", %{"environment" => "proj"})
      ]

      {:ok, _} = Manifest.apply_manifest(user.id, resources)
      {:ok, results} = Manifest.apply_manifest(user.id, resources)

      # The secret is re-encrypted on every apply, so it keeps reporting
      # `upserted` while the row it belongs to reports `unchanged`.
      assert [
               %{kind: "Environment", action: :unchanged, secrets: [%{action: :upserted}]},
               %{kind: "Agent", action: :unchanged}
             ] = results

      assert length(Environments.list_environments(user.id)) == 1
      assert length(Agents.list_agents(user.id, [])) == 1
    end

    test "a changed spec still reports updated", %{user: user} do
      {:ok, _} = Manifest.apply_manifest(user.id, [env_resource("proj")])

      {:ok, [%{kind: "Environment", action: :updated}]} =
        Manifest.apply_manifest(user.id, [env_resource("proj", %{"setup_script" => "echo hi"})])

      assert Environments.get_environment_by_name("proj", user.id).setup_script == "echo hi"
    end

    # CLAUDE.md: "Only record what happened. ... a no-op sync records nothing."
    # An apply that writes nothing must leave the trail exactly as it found it,
    # or every CI run adds a row per resource saying a record nobody touched
    # was updated.
    test "an identical re-apply writes no audit rows at all", %{user: user} do
      resources = [env_resource("proj"), agent_resource("researcher", %{"environment" => "proj"})]

      {:ok, first} = Manifest.apply_manifest(user.id, resources)
      assert Enum.all?(first, &(&1.action == :created))
      before = actions_for(user)

      {:ok, second} = Manifest.apply_manifest(user.id, resources)
      assert Enum.all?(second, &(&1.action == :unchanged))
      assert actions_for(user) == before
    end

    defp actions_for(user),
      do: user.id |> Audit.list_recent_for_user(500) |> Enum.map(& &1.action)

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
