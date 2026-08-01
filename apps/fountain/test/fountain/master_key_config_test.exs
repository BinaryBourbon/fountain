defmodule Fountain.MasterKeyConfigTest do
  @moduledoc """
  Evaluates `config/runtime.exs` the way the release config provider does.

  The dev-key fallback lived entirely in this file, so no unit test of
  application code could reach it: `Crypto` was handed a key and had no way to
  know it came from a constant committed to this repo. These cases pin the
  guard itself.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)
  @dev_fallback :crypto.hash(:sha256, "fountain:dev:master_secrets_key")

  setup do
    previous = System.get_env()

    # Prod refuses to boot with no mail delivery configured; these cases are
    # about the master key, so give them one.
    System.put_env("RESEND_API_KEY", "re_test_key")
    for k <- ~w(SMTP_HOST EMAIL_DELIVERY), do: System.delete_env(k)

    on_exit(fn ->
      System.put_env(previous)

      for k <- ~w(MASTER_SECRETS_KEY PHX_SERVER),
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    :ok
  end

  defp read_prod! do
    Config.Reader.read!(@runtime_exs, env: :prod)[:fountain][:master_secrets_key]
  end

  test "prod without PHX_SERVER raises rather than falling back to the dev key" do
    # The original guard was {nil, :prod, true}, so every prod process started
    # without PHX_SERVER=true — release eval tasks, migrations, seeds, a remote
    # console — silently received @dev_fallback.
    System.delete_env("MASTER_SECRETS_KEY")
    System.delete_env("PHX_SERVER")

    assert_raise RuntimeError, ~r/MASTER_SECRETS_KEY/, fn -> read_prod!() end
  end

  test "prod with PHX_SERVER also raises" do
    System.delete_env("MASTER_SECRETS_KEY")
    System.put_env("PHX_SERVER", "true")

    assert_raise RuntimeError, ~r/MASTER_SECRETS_KEY/, fn -> read_prod!() end
  end

  test "a supplied key is used verbatim, never the dev fallback" do
    key = :crypto.strong_rand_bytes(32)
    System.put_env("MASTER_SECRETS_KEY", Base.url_encode64(key, padding: false))
    System.delete_env("PHX_SERVER")

    assert read_prod!() == key
    refute read_prod!() == @dev_fallback
  end

  test "a malformed key is rejected rather than silently truncated" do
    System.put_env("MASTER_SECRETS_KEY", "too-short")
    System.delete_env("PHX_SERVER")

    assert_raise RuntimeError, ~r/32 bytes/, fn -> read_prod!() end
  end
end
