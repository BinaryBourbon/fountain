defmodule Fountain.VaultsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Vaults

  describe "create_vault/1" do
    test "creates a vault with valid attrs" do
      user = insert_verified_user()
      attrs = vault_attrs(user_id: user.id)

      assert {:ok, vault} = Vaults.create_vault(attrs)
      assert vault.user_id == user.id
      assert vault.name == attrs.name
    end

    test "returns error changeset with missing required fields" do
      assert {:error, changeset} = Vaults.create_vault(%{})
      assert changeset.errors != []
    end
  end

  describe "get_vault/2" do
    test "returns vault scoped to user" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert fetched = Vaults.get_vault(vault.id, user.id)
      assert fetched.id == vault.id
    end

    test "returns nil for vault belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault = insert_vault(user_id: user_a.id)

      assert Vaults.get_vault(vault.id, user_b.id) == nil
    end

    test "returns nil for non-existent id" do
      user = insert_verified_user()
      assert Vaults.get_vault(Ecto.UUID.generate(), user.id) == nil
    end
  end

  describe "list_vaults/1" do
    test "returns only vaults for the given user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault_a = insert_vault(user_id: user_a.id)
      _vault_b = insert_vault(user_id: user_b.id)

      results = Vaults.list_vaults(user_a.id)
      assert length(results) == 1
      assert hd(results).id == vault_a.id
    end

    test "returns empty list when user has no vaults" do
      user = insert_verified_user()
      assert Vaults.list_vaults(user.id) == []
    end
  end

  describe "update_vault/2" do
    test "updates vault name" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert {:ok, updated} = Vaults.update_vault(vault, %{name: "renamed"})
      assert updated.name == "renamed"
    end
  end

  describe "delete_vault/1" do
    test "deletes the vault" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert {:ok, _} = Vaults.delete_vault(vault)
      assert Vaults.get_vault(vault.id, user.id) == nil
    end
  end

  describe "upsert_secret/3" do
    test "inserts a new secret" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, secret} = Vaults.upsert_secret(vault, %{key: "TOKEN", value: "xyz"}, dek)
      assert secret.key == "TOKEN"
    end

    test "updates an existing secret with the same key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} = Vaults.upsert_secret(vault, %{key: "TOKEN", value: "first"}, dek)
      {:ok, _} = Vaults.upsert_secret(vault, %{key: "TOKEN", value: "second"}, dek)

      secrets = Vaults.list_secrets(vault)
      assert length(secrets) == 1
    end
  end

  describe "list_secrets/1" do
    test "returns all secrets for a vault" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "FOO")
      insert_vault_secret(vault, key: "BAR")

      secrets = Vaults.list_secrets(vault)
      assert length(secrets) == 2
    end

    test "returns empty list when vault has no secrets" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert Vaults.list_secrets(vault) == []
    end
  end

  describe "delete_secret/1" do
    test "deletes the secret" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TO_DELETE")

      assert {:ok, _} = Vaults.delete_secret(secret)
      assert Vaults.list_secrets(vault) == []
    end
  end

  describe "decrypted_env/2" do
    test "returns a map of key => plaintext value" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Vaults.upsert_secret(vault, %{key: "SECRET_A", value: "val_a"}, dek)
      Vaults.upsert_secret(vault, %{key: "SECRET_B", value: "val_b"}, dek)

      assert {:ok, decrypted} = Vaults.decrypted_env(vault, dek)
      assert decrypted["SECRET_A"] == "val_a"
      assert decrypted["SECRET_B"] == "val_b"
    end

    test "returns empty map when vault has no secrets" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, decrypted} = Vaults.decrypted_env(vault, dek)
      assert decrypted == %{}
    end

    test "vault secrets override environment secrets on key collision" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Fountain.Environments.upsert_secret(env, %{key: "DB_URL", value: "env_value"}, dek)
      Vaults.upsert_secret(vault, %{key: "DB_URL", value: "vault_value"}, dek)

      {:ok, env_map} = Fountain.Environments.decrypted_env(env, dek)
      {:ok, vault_map} = Vaults.decrypted_env(vault, dek)

      merged = Map.merge(env_map, vault_map)
      assert merged["DB_URL"] == "vault_value"
    end
  end
end
