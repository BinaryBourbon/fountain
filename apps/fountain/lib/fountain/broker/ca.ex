defmodule Fountain.Broker.CA do
  @moduledoc """
  The certificate authority the egress proxy signs with (ADR 0019 §8, native
  broker).

  A brokered sandbox trusts one root, and the proxy presents a leaf for each
  host the sandbox `CONNECT`s to, signed by that root. Every Fountain
  replica must present leaves the sandbox trusts, whichever one the
  ingress hands the connection to, and a sandbox that survived a restart
  must still trust what a fresh replica signs. So the root is not generated
  and stored: it is **derived** from `MASTER_SECRETS_KEY` with HKDF, and the
  certificate's subject, serial and validity are fixed, so every replica
  computes the same key, subject and serial from the same master key. The
  self-signature bytes differ per derivation (ECDSA is randomised), which
  does not matter: a client matches a trust anchor by subject and public
  key and never checks a root's own signature. Rotating the master key
  rotates the CA; nothing else does.

  The private key never leaves the process: it is kept in `persistent_term`
  after the first derivation. The leaf for a host is derived once per
  replica and cached in `Fountain.Broker.Certs`.
  """

  @curve :secp256r1
  @info "fountain.broker.ca"
  # Fixed so that every replica derives the same certificate from the same
  # key. A validity window that started at the launch and runs twenty years
  # is a constant, not a clock read.
  @not_before ~U[2026-05-01 00:00:00Z]
  @not_after ~U[2046-05-01 00:00:00Z]
  @leaf_days 30

  @doc "The root certificate as PEM, for the sandbox trust store."
  @spec pem() :: String.t()
  def pem, do: cert() |> X509.Certificate.to_pem()

  @doc "The root certificate."
  @spec cert() :: X509.Certificate.t()
  def cert, do: elem(root(), 0)

  @doc "The root certificate as DER, for a `cacerts` option."
  @spec der() :: binary()
  def der, do: cert() |> X509.Certificate.to_der()

  @doc """
  A leaf certificate and key for `host`, signed by the root, as the
  `[cert: der, key: {:ECPrivateKey, der}]` pair `:ssl` takes.
  """
  @spec leaf(String.t()) :: [cert: binary(), key: {:ECPrivateKey, binary()}]
  def leaf(host) when is_binary(host) do
    {ca_cert, ca_key} = root()
    key = X509.PrivateKey.new_ec(@curve)
    now = DateTime.utc_now()

    validity =
      X509.Certificate.Validity.new(
        DateTime.add(now, -300, :second),
        DateTime.add(now, @leaf_days * 86_400, :second)
      )

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=#{host}", ca_cert, ca_key,
        template: :server,
        validity: validity,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([host])]
      )

    [cert: X509.Certificate.to_der(cert), key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}]
  end

  @doc false
  @spec root() :: {X509.Certificate.t(), X509.PrivateKey.t()}
  def root do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil ->
        pair = derive_root()
        :persistent_term.put({__MODULE__, :root}, pair)
        pair

      pair ->
        pair
    end
  end

  @doc false
  # Tests swap the master key; the cached root must follow it.
  def reset, do: :persistent_term.erase({__MODULE__, :root})

  defp derive_root do
    key = derive_key(master_key())

    validity = X509.Certificate.Validity.new(@not_before, @not_after)

    cert =
      X509.Certificate.self_signed(key, "/CN=Fountain Broker CA/O=Fountain",
        template: :root_ca,
        validity: validity,
        serial: serial(key)
      )

    {cert, key}
  end

  # HKDF-SHA256 over the master key, reduced into the curve's scalar field.
  # The reduction bias on a 256-bit output against P-256's order is under
  # 2^-32; the key is not a signature-oracle target at that precision.
  defp derive_key(master) do
    prk = :crypto.mac(:hmac, :sha256, "fountain.broker.salt", master)
    okm = :crypto.mac(:hmac, :sha256, prk, @info <> <<1>>)
    n = curve_order()
    scalar = rem(:binary.decode_unsigned(okm), n - 1) + 1
    priv = <<scalar::unsigned-big-integer-size(256)>>
    {pub, ^priv} = :crypto.generate_key(:ecdh, @curve, priv)

    {:ECPrivateKey, 1, priv, {:namedCurve, :pubkey_cert_records.namedCurves(@curve)}, pub,
     :asn1_NOVALUE}
  end

  # P-256's group order, from the curve parameters OTP ships.
  defp curve_order do
    {_field, _curve, _base, order, _cofactor} = :crypto.ec_curve(@curve)
    :binary.decode_unsigned(order)
  end

  # A serial from the public key, so it is as stable as the key itself.
  defp serial(key) do
    {:ECPrivateKey, _, _, _, pub, _} = key
    <<n::unsigned-big-integer-size(64), _::binary>> = :crypto.hash(:sha256, pub)
    Bitwise.bsr(n, 1) + 1
  end

  defp master_key do
    case Application.fetch_env!(:fountain, :master_secrets_key) do
      <<_::binary-32>> = k -> k
      other -> raise "MASTER_SECRETS_KEY must be 32 bytes, got #{byte_size(other)}"
    end
  end
end
