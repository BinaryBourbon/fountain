defmodule Fountain.CryptoTest do
  use ExUnit.Case, async: true

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
end
