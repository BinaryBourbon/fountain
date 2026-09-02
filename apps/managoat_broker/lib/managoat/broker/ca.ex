defmodule Managoat.Broker.CA do
  @moduledoc """
  The certificate authority the egress proxy signs with.

  A brokered sandbox trusts one root, and the proxy presents a leaf for each
  host the sandbox `CONNECT`s to, signed by that root. Every replica of the
  host application must present leaves the sandbox trusts, whichever one
  the ingress hands the connection to, and a sandbox that survived a
  restart must still trust what a fresh replica signs. So the root is not
  generated and stored: it is **derived** from a 32-byte `seed` the host
  passes at start (HKDF-SHA256, reduced into P-256's scalar field), and the
  certificate's subject, serial and validity are fixed, so every replica
  computes the same key, subject and serial from the same seed. Rotating
  the seed rotates the CA; nothing else does.

  The self-signature bytes differ per derivation, because ECDSA signing is
  randomised. That is harmless: a client matches a trust anchor by subject
  and public key and never checks a root's own signature, and `ca_test.exs`
  proves a leaf signed after a re-derivation chains to the first root.

  The seed is the host's to derive. It must not be a key the host uses for
  anything else: derive one from a master key with a fixed info string, so
  the CA key is never the storage key. Every function here is pure; the
  listener caches the root and the leaves in `Managoat.Broker.Certs`.
  """

  @curve :secp256r1
  @salt "managoat.broker.salt"
  @info "managoat.broker.ca"
  # Fixed so that every replica derives the same certificate from the same
  # seed. A validity window that starts at a constant and runs twenty years
  # is a constant, not a clock read.
  @not_before ~U[2026-05-01 00:00:00Z]
  @not_after ~U[2046-05-01 00:00:00Z]
  @leaf_days 30

  @typedoc "The root certificate and its private key."
  @type root :: {X509.Certificate.t(), X509.PrivateKey.t()}

  @doc "The root certificate as PEM, for a sandbox trust store."
  @spec pem(binary()) :: String.t()
  def pem(seed), do: seed |> root() |> elem(0) |> X509.Certificate.to_pem()

  @doc "The root certificate as DER, for a `cacerts` option."
  @spec der(binary()) :: binary()
  def der(seed), do: seed |> root() |> elem(0) |> X509.Certificate.to_der()

  @doc """
  Derive the root from a 32-byte seed. Deterministic in key, subject and
  serial; see the moduledoc for the signature.
  """
  @spec root(binary()) :: root()
  def root(<<_::binary-32>> = seed) do
    key = derive_key(seed)
    validity = X509.Certificate.Validity.new(@not_before, @not_after)

    cert =
      X509.Certificate.self_signed(key, "/CN=Managoat Broker CA/O=Managoat",
        template: :root_ca,
        validity: validity,
        serial: serial(key)
      )

    {cert, key}
  end

  def root(other) when is_binary(other) do
    raise ArgumentError, "the broker CA seed must be 32 bytes, got #{byte_size(other)}"
  end

  @doc """
  A leaf certificate and key for `host`, signed by `root`, as the
  `[cert: der, key: {:ECPrivateKey, der}]` pair `:ssl` takes.
  """
  @spec leaf(String.t(), root()) :: [cert: binary(), key: {:ECPrivateKey, binary()}]
  def leaf(host, {ca_cert, ca_key}) when is_binary(host) do
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

  # HKDF-SHA256 over the seed, reduced into the curve's scalar field. The
  # reduction bias on a 256-bit output against P-256's order is under 2^-32;
  # the key is not a signature-oracle target at that precision.
  defp derive_key(seed) do
    prk = :crypto.mac(:hmac, :sha256, @salt, seed)
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
end
