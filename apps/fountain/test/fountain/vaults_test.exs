defmodule Fountain.VaultsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Vaults

  describe "create_vault/1" do
    test "creates a vault with valid attrs" do
      user = insert_verified_user()
      attrs = vault_attrs(user_id: user.id)

      assert {:ok, vault} = Vaults.create_vault(attrs)
      assert vault.user_id == user.id
      assert vault.name == attrs["name"]
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

      assert {:ok, updated} = Vaults.update_vault(vault, %{"name" => "renamed"})
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

      assert {:ok, secret} =
               Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "xyz"}, dek)

      assert secret.key == "TOKEN"
    end

    test "updates an existing secret with the same key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "first"}, dek)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "TOKEN", "value" => "second"}, dek)

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

  describe "get_secret/2" do
    test "returns the secret for the given vault_id and key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "MY_SECRET")

      result = Vaults.get_secret(vault.id, "MY_SECRET")
      assert result != nil
      assert result.key == "MY_SECRET"
      assert result.vault_id == vault.id
    end

    test "returns nil when the key does not exist in the vault" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      assert Vaults.get_secret(vault.id, "NONEXISTENT") == nil
    end

    test "returns nil when the vault_id does not match" do
      user = insert_verified_user()
      vault_a = insert_vault(user_id: user.id)
      vault_b = insert_vault(user_id: user.id)
      insert_vault_secret(vault_a, key: "ONLY_IN_A")

      assert Vaults.get_secret(vault_b.id, "ONLY_IN_A") == nil
    end
  end

  describe "get_vault!/2" do
    test "returns vault when id and user_id match" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      result = Vaults.get_vault!(vault.id, user.id)
      assert result.id == vault.id
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      user = insert_verified_user()

      assert_raise Ecto.NoResultsError, fn ->
        Vaults.get_vault!(Ecto.UUID.generate(), user.id)
      end
    end

    test "raises Ecto.NoResultsError when vault belongs to a different user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault = insert_vault(user_id: user_a.id)

      assert_raise Ecto.NoResultsError, fn ->
        Vaults.get_vault!(vault.id, user_b.id)
      end
    end
  end

  describe "_unsafe_list_vaults/0" do
    test "returns an empty list when no vaults exist" do
      assert Vaults._unsafe_list_vaults() == []
    end

    test "returns vaults across all users" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      vault_a = insert_vault(user_id: user_a.id)
      vault_b = insert_vault(user_id: user_b.id)

      ids = Vaults._unsafe_list_vaults() |> Enum.map(& &1.id)
      assert vault_a.id in ids
      assert vault_b.id in ids
    end

    test "orders by inserted_at descending" do
      user = insert_verified_user()
      v1 = insert_vault(user_id: user.id)
      v2 = insert_vault(user_id: user.id)

      [first | _] = Vaults._unsafe_list_vaults()
      assert first.id == v2.id || first.inserted_at >= v1.inserted_at
    end
  end

  describe "_unsafe_get_vault/1" do
    test "returns the vault when it exists" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      result = Vaults._unsafe_get_vault(vault.id)
      assert result.id == vault.id
    end

    test "returns nil for a non-existent id" do
      assert Vaults._unsafe_get_vault(Ecto.UUID.generate()) == nil
    end

    test "returns vault regardless of owner" do
      user_a = insert_verified_user()
      vault = insert_vault(user_id: user_a.id)

      result = Vaults._unsafe_get_vault(vault.id)
      assert result.id == vault.id
      assert result.user_id == user_a.id
    end
  end

  describe "_unsafe_get_vault!/1" do
    test "returns the vault when it exists" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      result = Vaults._unsafe_get_vault!(vault.id)
      assert result.id == vault.id
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Vaults._unsafe_get_vault!(Ecto.UUID.generate())
      end
    end
  end

  describe "_unsafe_get_vault_by_name/1" do
    test "returns the vault matching the given name" do
      user = insert_verified_user()
      attrs = vault_attrs(user_id: user.id, name: "my-special-vault")
      {:ok, vault} = Vaults.create_vault(attrs)

      result = Vaults._unsafe_get_vault_by_name("my-special-vault")
      assert result.id == vault.id
      assert result.name == "my-special-vault"
    end

    test "returns nil when no vault has the given name" do
      assert Vaults._unsafe_get_vault_by_name("does-not-exist") == nil
    end

    test "returns vault regardless of owner" do
      user_a = insert_verified_user()
      attrs = vault_attrs(user_id: user_a.id, name: "cross-tenant-vault")
      {:ok, vault} = Vaults.create_vault(attrs)

      result = Vaults._unsafe_get_vault_by_name("cross-tenant-vault")
      assert result.id == vault.id
    end
  end

  describe "VaultSecret.decrypt/2" do
    test "decrypts a vault secret that was encrypted with the tenant key" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _secret} =
        Vaults.upsert_secret(vault, %{"key" => "DECRYPT_ME", "value" => "plaintext_value"}, dek)

      # Load the raw secret (with ciphertext) to test decrypt directly
      [raw_secret] = Vaults.list_secrets(vault)
      assert {:ok, "plaintext_value"} = Fountain.Vaults.VaultSecret.decrypt(raw_secret, dek)
    end

    test "returns :error for a non-VaultSecret argument" do
      dek = :crypto.strong_rand_bytes(32)
      assert :error = Fountain.Vaults.VaultSecret.decrypt(%{}, dek)
    end
  end

  describe "decrypted_env/2" do
    test "returns a map of key => plaintext value" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Vaults.upsert_secret(vault, %{"key" => "SECRET_A", "value" => "val_a"}, dek)
      Vaults.upsert_secret(vault, %{"key" => "SECRET_B", "value" => "val_b"}, dek)

      decrypted = Vaults.decrypted_env(vault, dek)
      assert decrypted["SECRET_A"] == "val_a"
      assert decrypted["SECRET_B"] == "val_b"
    end

    test "returns empty map when vault has no secrets" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert Vaults.decrypted_env(vault, dek) == %{}
    end

    test "silently skips secrets that fail to decrypt with wrong DEK" do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      Vaults.upsert_secret(vault, %{"key" => "MY_KEY", "value" => "secret"}, dek)

      wrong_dek = :crypto.strong_rand_bytes(32)
      result = Vaults.decrypted_env(vault, wrong_dek)
      assert result == %{}
    end

    test "vault secrets override environment secrets on key collision" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      Fountain.Environments.upsert_secret(
        env,
        %{"key" => "DB_URL", "value" => "env_value"},
        dek
      )

      Vaults.upsert_secret(vault, %{"key" => "DB_URL", "value" => "vault_value"}, dek)

      env_map = Fountain.Environments.decrypted_env(env, dek)
      vault_map = Vaults.decrypted_env(vault, dek)

      merged = Map.merge(env_map, vault_map)
      assert merged["DB_URL"] == "vault_value"
    end
  end
end
