defmodule Managoat.McpAuth.UrlGuardConfigTest do
  # Synchronous by default: this test changes global application env and must
  # not overlap async test modules.
  use ExUnit.Case

  alias Managoat.McpAuth.UrlGuard

  setup do
    previous = Application.get_env(:managoat_mcp_auth, :allow_private_hosts)

    on_exit(fn ->
      Application.put_env(:managoat_mcp_auth, :allow_private_hosts, previous)
    end)

    :ok
  end

  test "check/1 honours the application config default" do
    Application.put_env(:managoat_mcp_auth, :allow_private_hosts, false)

    assert {:error, :unresolvable} = UrlGuard.check("https://no-such-host.invalid/a")
  end
end
