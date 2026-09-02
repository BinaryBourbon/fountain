defmodule Managoat.Runner.ConfigTest do
  @moduledoc """
  Reads and, for the missing-host case, temporarily clears global
  application env, so `async: false`: ExUnit runs these after every async
  module has finished, and no other module sees the gap.
  """
  use ExUnit.Case, async: false

  alias Managoat.Runner.Config

  setup do
    configured = Application.get_env(:managoat_runner, :host)
    on_exit(fn -> Application.put_env(:managoat_runner, :host, configured) end)
    %{configured: configured}
  end

  test "the configured host is the default", %{configured: configured} do
    assert Config.host!() == configured
    assert Config.host!(%{}) == configured
    assert Config.host!(%{host: nil}) == configured
  end

  test "an init map's host overrides the configured one" do
    assert Config.host!(%{host: SomeOther.Host}) == SomeOther.Host
  end

  test "no host anywhere raises a message naming the config key" do
    Application.delete_env(:managoat_runner, :host)

    assert_raise ArgumentError, ~r/config :managoat_runner, host: Module/, fn ->
      Config.host!()
    end

    assert_raise ArgumentError, ~r/Managoat\.Runner\.Host\.Local/, fn ->
      Config.host!(%{host: nil})
    end

    assert Config.host!(%{host: SomeOther.Host}) == SomeOther.Host
  end
end
