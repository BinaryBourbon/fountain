defmodule Managoat.BrokerTest do
  # The listener's child spec: what it requires, and what it exposes once up.
  use ExUnit.Case, async: true

  alias Managoat.Broker
  alias Managoat.Broker.CA
  alias Managoat.Broker.Store.Memory

  @seed :crypto.hash(:sha256, "broker test seed")

  test "every required option is named when missing" do
    for {missing, opts} <- [
          {:port, [store: Memory, ca_seed: @seed]},
          {:store, [port: 0, ca_seed: @seed]},
          {:ca_seed, [port: 0, store: Memory]}
        ] do
      assert_raise ArgumentError, ~r/#{inspect(missing)}/, fn -> Broker.start_link(opts) end
    end
  end

  test "a seed that is not 32 bytes is refused before anything listens" do
    assert_raise ArgumentError, ~r/32 bytes/, fn ->
      Broker.start_link(port: 0, store: Memory, ca_seed: "short")
    end
  end

  test "up, it reports its port, that it runs, and the root it signs with" do
    name = :"broker_#{System.unique_integer([:positive])}"
    refute Broker.running?(name)

    start_supervised!({Broker, name: name, port: 0, store: Memory, ca_seed: @seed})

    assert Broker.running?(name)
    assert Broker.port(name) > 0
    assert Broker.ca_pem_for_seed(@seed) =~ "BEGIN CERTIFICATE"

    # The PEM bytes vary per derivation (randomised self-signature); the
    # anchor does not.
    assert anchor(Broker.ca_pem(name)) == anchor(CA.pem(@seed))
  end

  test "the child spec is keyed by name, so two listeners coexist in one tree" do
    a = :"broker_#{System.unique_integer([:positive])}"
    b = :"broker_#{System.unique_integer([:positive])}"

    assert %{id: ^a, type: :supervisor} = Broker.child_spec(name: a, port: 0)
    assert %{id: Managoat.Broker} = Broker.child_spec(port: 0)

    start_supervised!({Broker, name: a, port: 0, store: Memory, ca_seed: @seed})
    start_supervised!({Broker, name: b, port: 0, store: Memory, ca_seed: @seed})
    refute Broker.port(a) == Broker.port(b)
  end

  defp anchor(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    cert = X509.Certificate.from_der!(der)
    {X509.Certificate.subject(cert), X509.Certificate.public_key(cert)}
  end
end
