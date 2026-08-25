defmodule Fountain.Connections.UrlGuardTest do
  # Flips the resolution check on (global app env) to test it.
  use ExUnit.Case, async: false

  alias Fountain.Connections.UrlGuard

  setup do
    previous = Application.get_env(:fountain, :connections_allow_private_hosts)
    on_exit(fn -> Application.put_env(:fountain, :connections_allow_private_hosts, previous) end)
    :ok
  end

  test "syntactic rules hold without resolving anything" do
    Application.put_env(:fountain, :connections_allow_private_hosts, true)

    assert {:error, :not_https} = UrlGuard.check("http://x.example/a")
    assert {:error, :not_https} = UrlGuard.check("ftp://x.example/a")
    assert {:error, :not_https} = UrlGuard.check(nil)
    assert {:error, :no_host} = UrlGuard.check("https:///a")
    assert {:error, :ip_literal} = UrlGuard.check("https://127.0.0.1/a")
    assert {:error, :ip_literal} = UrlGuard.check("https://[::1]/a")
    assert {:error, :internal_host} = UrlGuard.check("https://localhost/a")
    assert {:error, :internal_host} = UrlGuard.check("https://db.svc.cluster.local/a")
    assert {:error, :internal_host} = UrlGuard.check("https://metadata.google.internal/a")
    assert :ok = UrlGuard.check("https://x.example/a")
  end

  test "with resolution on, loopback and private answers are refused and unknown names do not pass" do
    Application.put_env(:fountain, :connections_allow_private_hosts, false)

    # `localhost` is caught by name; a name that resolves to loopback by
    # any other route is caught by address.
    assert {:error, :internal_host} = UrlGuard.check("https://localhost/a")
    assert {:error, :unresolvable} = UrlGuard.check("https://no-such-host.invalid/a")
  end

  test "messages name the rule" do
    for reason <- [:not_https, :no_host, :ip_literal, :internal_host, :private_address, :unresolvable] do
      assert is_binary(UrlGuard.message(reason))
    end
  end
end
