defmodule Managoat.McpAuth.UrlGuardTest do
  use ExUnit.Case, async: true

  alias Managoat.McpAuth.UrlGuard

  test "syntactic rules hold without resolving anything" do
    opts = [allow_private_hosts: true]

    assert {:error, :not_https} = UrlGuard.check("http://x.example/a", opts)
    assert {:error, :not_https} = UrlGuard.check("ftp://x.example/a", opts)
    assert {:error, :not_https} = UrlGuard.check(nil, opts)
    assert {:error, :no_host} = UrlGuard.check("https:///a", opts)
    assert {:error, :ip_literal} = UrlGuard.check("https://127.0.0.1/a", opts)
    assert {:error, :ip_literal} = UrlGuard.check("https://[::1]/a", opts)
    assert {:error, :internal_host} = UrlGuard.check("https://localhost/a", opts)
    assert {:error, :internal_host} = UrlGuard.check("https://db.svc.cluster.local/a", opts)
    assert {:error, :internal_host} = UrlGuard.check("https://metadata.google.internal/a", opts)
    assert :ok = UrlGuard.check("https://x.example/a", opts)
  end

  test "with resolution on, internal and unknown names do not pass" do
    opts = [allow_private_hosts: false]

    assert {:error, :internal_host} = UrlGuard.check("https://localhost/a", opts)
    assert {:error, :unresolvable} = UrlGuard.check("https://no-such-host.invalid/a", opts)
  end

  test "messages name every rule" do
    for reason <- [
          :not_https,
          :no_host,
          :ip_literal,
          :internal_host,
          :private_address,
          :unresolvable
        ] do
      assert is_binary(UrlGuard.message(reason))
    end
  end
end
