defmodule Fountain.SandboxConfigTest do
  # Mutates global application env, so it must not run alongside anything
  # that reads sandbox configuration.
  use ExUnit.Case, async: false

  alias Fountain.Sandbox

  setup do
    previous = Application.get_env(:fountain, :sprites_token)
    previous_e2b = Application.get_env(:fountain, :e2b_api_key)

    on_exit(fn ->
      restore(:sprites_token, previous)
      restore(:e2b_api_key, previous_e2b)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  test "a provider is enabled only when its credential is configured" do
    Application.delete_env(:fountain, :sprites_token)
    refute Sandbox.enabled?(:sprites)
    assert Sandbox.enabled_providers() == []

    Application.put_env(:fountain, :sprites_token, "tok")
    assert Sandbox.enabled?(:sprites)
    assert Sandbox.enabled_providers() == [:sprites]
  end

  test "a credential without a registered adapter does not enable the provider" do
    # E2B credentials can be configured ahead of the adapter shipping; the
    # provider stays unusable until its module is in :sandbox_adapters.
    Application.put_env(:fountain, :e2b_api_key, "e2b_x")
    refute Sandbox.enabled?(:e2b)
  end
end
