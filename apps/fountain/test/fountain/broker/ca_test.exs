defmodule Fountain.Broker.CATest do
  use ExUnit.Case, async: false

  alias Fountain.Broker.CA

  setup do
    CA.reset()
    on_exit(&CA.reset/0)
  end

  # What a trust anchor is matched on. The self-signature is not in here:
  # ECDSA signing is randomised, so it differs per derivation, and no client
  # consults it.
  defp anchor(der) do
    cert = X509.Certificate.from_der!(der)

    {X509.Certificate.subject(cert), X509.Certificate.public_key(cert),
     X509.Certificate.serial(cert)}
  end

  test "the root is derived from the master key: same key, same anchor" do
    first = anchor(CA.der())
    CA.reset()
    assert anchor(CA.der()) == first
  end

  test "a leaf signed after a re-derivation still chains to the first root" do
    root = CA.der()
    CA.reset()
    [cert: leaf, key: _] = CA.leaf("github.com")
    assert {:ok, _} = :public_key.pkix_path_validation(root, [leaf], [])
  end

  test "a different master key is a different CA" do
    previous = Application.fetch_env!(:fountain, :master_secrets_key)
    on_exit(fn -> Application.put_env(:fountain, :master_secrets_key, previous) end)

    first = anchor(CA.der())
    Application.put_env(:fountain, :master_secrets_key, :crypto.strong_rand_bytes(32))
    CA.reset()
    refute anchor(CA.der()) == first
  end

  test "the root is a CA and a leaf for a host chains to it" do
    root = CA.der()
    [cert: leaf, key: {:ECPrivateKey, _}] = CA.leaf("api.github.com")

    assert {:ok, _} = :public_key.pkix_path_validation(root, [leaf], [])

    otp = X509.Certificate.from_der!(leaf)
    assert X509.Certificate.subject(otp) |> X509.RDNSequence.to_string() =~ "api.github.com"

    {:Extension, _, _, names} = X509.Certificate.extension(otp, :subject_alt_name)
    assert {:dNSName, ~c"api.github.com"} in names
  end

  test "the PEM is one certificate" do
    assert [{:Certificate, _, :not_encrypted}] = :public_key.pem_decode(CA.pem())
  end
end
