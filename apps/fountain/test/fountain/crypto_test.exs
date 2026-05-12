defmodule Fountain.CryptoTest do
  use Fountain.DataCase, async: true

  alias Fountain.Crypto

  @key :crypto.strong_rand_bytes(32)
  @short_key :crypto.strong_rand_bytes(16)

  describe "encrypt/3 and decrypt/3" do
    test "round-trips plaintext with a 32-byte key" do
      plaintext = "my secret value"
      ciphertext = Crypto.encrypt(plaintext, @key)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext, @key)
    end

    test "round-trips with a custom aad" do
      plaintext = "another value"
      aad = "custom.aad"
      ciphertext = Crypto.encrypt(plaintext, @key, aad)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext, @key, aad)
    end

    test "decryption fails with the wrong key" do
      ciphertext = Crypto.encrypt("secret", @key)
      wrong_key = :crypto.strong_rand_bytes(32)
      assert :error = Crypto.decrypt(ciphertext, wrong_key)
    end

    test "decryption fails with the wrong aad" do
      ciphertext = Crypto.encrypt("secret", @key, "aad1")
      assert :error = Crypto.decrypt(ciphertext, @key, "aad2")
    end

    test "decryption returns :error for truncated ciphertext" do
      assert :error = Crypto.decrypt(<<1, 2, 3>>, @key)
    end

    test "decryption returns :error for empty binary" do
      assert :error = Crypto.decrypt(<<>>, @key)
    end

    test "encrypt raises on a non-32-byte key" do
      assert_raise ArgumentError, ~r/32 bytes/, fn ->
        Crypto.encrypt("secret", @short_key)
      end
    end

    test "decrypt raises ArgumentError when called with a key that is not 32 bytes" do
      ciphertext = Crypto.encrypt("secret", @key)

      assert_raise ArgumentError, ~r/32 bytes/, fn ->
        Crypto.decrypt(ciphertext, @short_key)
      end
    end

    test "each encryption of the same plaintext produces a different ciphertext (random IV)" do
      c1 = Crypto.encrypt("same", @key)
      c2 = Crypto.encrypt("same", @key)
      assert c1 != c2
    end

    test "round-trips empty plaintext" do
      ciphertext = Crypto.encrypt("", @key)
      assert {:ok, ""} = Crypto.decrypt(ciphertext, @key)
    end
  end

  describe "generate_dek/0" do
    test "returns 32 random bytes" do
      dek = Crypto.generate_dek()
      assert byte_size(dek) == 32
    end

    test "two calls return different values" do
      assert Crypto.generate_dek() != Crypto.generate_dek()
    end
  end

  describe "wrap_dek/1" do
    test "produces a binary of 60 bytes (iv=12 + tag=16 + dek=32)" do
      dek = Crypto.generate_dek()
      wrapped = Crypto.wrap_dek(dek)
      assert byte_size(wrapped) == 60
    end

    test "raises on non-32-byte input" do
      assert_raise FunctionClauseError, fn ->
        Crypto.wrap_dek(:crypto.strong_rand_bytes(16))
      end
    end

    test "wrapped DEK can be recovered with master key via decrypt/3" do
      dek = Crypto.generate_dek()
      master = Application.fetch_env!(:fountain, :master_secrets_key)
      wrapped = Crypto.wrap_dek(dek)
      assert {:ok, ^dek} = Crypto.decrypt(wrapped, master, "fountain.key_wrap")
    end

    test "two wraps of the same DEK produce different blobs (random IV per wrap)" do
      dek = Crypto.generate_dek()
      assert Crypto.wrap_dek(dek) != Crypto.wrap_dek(dek)
    end
  end

  describe "load_tenant_key/1" do
    test "returns {:error, :not_found} when no user_data_key row exists for the id" do
      # A random UUID has no UserDataKey row — no DB setup needed.
      assert {:error, :not_found} = Crypto.load_tenant_key(Ecto.UUID.generate())
    end

    test "returns {:error, :unwrap_failed} when wrapped_key is corrupted" do
      user = insert_verified_user()

      # Replace the valid UserDataKey created by register_user with garbage.
      import Ecto.Query, only: [from: 2]
      Fountain.Repo.delete_all(from k in Fountain.Accounts.UserDataKey, where: k.user_id == ^user.id)

      %Fountain.Accounts.UserDataKey{}
      |> Fountain.Accounts.UserDataKey.changeset(%{
        user_id: user.id,
        wrapped_key: :crypto.strong_rand_bytes(60),
        algorithm: "aes_256_gcm_wrap"
      })
      |> Fountain.Repo.insert!()

      assert {:error, :unwrap_failed} = Crypto.load_tenant_key(user.id)
    end
  end
end
