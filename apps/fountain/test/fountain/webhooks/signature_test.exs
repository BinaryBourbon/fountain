defmodule Fountain.Webhooks.SignatureTest do
  @moduledoc """
  The signing scheme (#700, ADR 0024).

  `verify/4` and the docs page both claim the header is
  `hmac_sha256(secret, "<t>.<body>")`. This file computes that independently
  rather than through `hex_mac/3`, so the two cannot drift together.
  """

  use ExUnit.Case, async: true

  alias Fountain.Webhooks.Signature

  @secret "whsec_test_secret"
  @body ~s({"id":"1","type":"conversation.turn.done"})

  defp independent_mac(secret, body, timestamp) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
    |> Base.encode16(case: :lower)
  end

  test "the header is t=<unix>,v1=<hex hmac over timestamp.body>" do
    header = Signature.header(@secret, @body, 1_755_203_400)

    assert header == "t=1755203400,v1=" <> independent_mac(@secret, @body, 1_755_203_400)
  end

  test "a body that differs by one byte produces a different signature" do
    a = Signature.header(@secret, @body, 1_755_203_400)
    b = Signature.header(@secret, @body <> " ", 1_755_203_400)

    refute a == b
  end

  test "the timestamp is inside the signed string, so it cannot be moved" do
    header = Signature.header(@secret, @body, 1_000)

    # Rewrite only the `t` and the signature no longer matches: an attacker
    # holding a captured body cannot carry it past the replay window.
    forged = String.replace(header, "t=1000", "t=2000")

    assert {:error, :mismatch} =
             Signature.verify(forged, @body, @secret, now: 2000, tolerance: 300)
  end

  describe "verify/4" do
    test "accepts what header/3 produced" do
      header = Signature.header(@secret, @body, 1_000)
      assert :ok = Signature.verify(header, @body, @secret, now: 1_000)
    end

    test "tolerates clock skew inside the window and refuses it outside" do
      header = Signature.header(@secret, @body, 1_000)

      assert :ok = Signature.verify(header, @body, @secret, now: 1_200, tolerance: 300)
      assert :ok = Signature.verify(header, @body, @secret, now: 800, tolerance: 300)

      assert {:error, :stale} =
               Signature.verify(header, @body, @secret, now: 1_400, tolerance: 300)
    end

    test "refuses the wrong secret" do
      header = Signature.header(@secret, @body, 1_000)

      assert {:error, :mismatch} =
               Signature.verify(header, @body, "whsec_someone_elses", now: 1_000)
    end

    test "refuses a header with no v1 pair" do
      assert {:error, :no_v1} = Signature.verify("t=1000,v2=abc", @body, @secret, now: 1_000)
    end

    test "refuses a malformed header rather than raising" do
      for bad <- ["", "nonsense", "t=,v1=abc", "t=abc,v1=def"] do
        assert {:error, :malformed} = Signature.verify(bad, @body, @secret, now: 1_000)
      end
    end

    test "reads the pairs by name, not by position" do
      header = Signature.header(@secret, @body, 1_000)
      [t, v1] = String.split(header, ",")

      assert :ok = Signature.verify("#{v1},#{t}", @body, @secret, now: 1_000)
      # A future v2 alongside v1 must not disturb a v1 verifier.
      assert :ok = Signature.verify("#{t},v2=ignored,#{v1}", @body, @secret, now: 1_000)
    end
  end
end
