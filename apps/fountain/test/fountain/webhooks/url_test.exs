defmodule Fountain.Webhooks.UrlTest do
  @moduledoc """
  The SSRF guard (#700, ADR 0024).

  This is the part webhook implementations usually get wrong, so it gets its
  own file. The three cases that matter are enumerated separately, because
  each defeats a different one of the three defences:

    * a literal private address, which shape validation catches;
    * a hostname that resolves somewhere private, which only an
      at-request-time resolution catches;
    * a redirect, which nothing here catches and which the delivery worker
      refuses to follow at all.
  """

  use ExUnit.Case, async: true

  alias Fountain.Webhooks.Url

  describe "scheme and shape" do
    test "https is accepted" do
      assert {:ok, %URI{}} = Url.validate("https://hooks.example.com/f")
    end

    test "a non-http scheme is refused whatever the http flag says" do
      assert {:error, "must use https"} = Url.validate("ftp://hooks.example.com/f")
      assert {:error, "must use https"} = Url.validate("file:///etc/passwd")
      assert {:error, "must use https"} = Url.validate("gopher://example.com/")
    end

    test "credentials in the URL are refused" do
      assert {:error, reason} = Url.validate("https://user:pass@hooks.example.com/f")
      assert reason =~ "credentials"
    end

    test "a URL with no host is refused" do
      assert {:error, "must include a host"} = Url.validate("https:///f")
    end

    test "a non-string is refused rather than raising" do
      assert {:error, _} = Url.validate(nil)
      assert {:error, _} = Url.validate(%{})
    end

    test "http is permitted here, because config/test.exs sets the flag" do
      assert Url.allow_http?()
      assert {:ok, _} = Url.validate("http://hooks.example.com/f")
    end
  end

  describe "a literal private address never gets stored" do
    for {url, what} <- [
          {"http://127.0.0.1/f", "loopback"},
          {"http://10.1.2.3/f", "RFC1918 ten"},
          {"http://172.16.9.9/f", "RFC1918 172"},
          {"http://192.168.1.1/f", "RFC1918 192.168"},
          {"http://169.254.169.254/latest/meta-data/", "the cloud metadata address"},
          {"http://100.64.0.1/f", "carrier-grade NAT"},
          {"http://0.0.0.0/f", "the unspecified address"},
          {"http://[::1]/f", "IPv6 loopback"},
          {"http://[fd00::1]/f", "IPv6 unique-local"},
          {"http://[fe80::1]/f", "IPv6 link-local"}
        ] do
      test "#{what} is refused" do
        assert {:error, _reason} = Url.validate(unquote(url))
      end
    end

    test "an IPv4 address smuggled inside an IPv6 one is unwrapped first" do
      # ::ffff:169.254.169.254 and 2002:a9fe:a9fe:: are the metadata address
      # wearing a different hat.
      assert {:error, reason} = Url.check_address({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      assert reason =~ "link-local"

      assert {:error, reason} = Url.check_address({0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 0})
      assert reason =~ "link-local"
    end

    test "a public address passes" do
      assert :ok = Url.check_address({93, 184, 216, 34})
      assert :ok = Url.check_address({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946})
    end
  end

  describe "resolution happens at request time, not only at create time" do
    test "a name that resolves to loopback is refused even though its shape is fine" do
      # `localhost` is the case every rebinding attack imitates: a perfectly
      # ordinary hostname whose answer is somewhere we must not go. Nothing
      # about the URL string says so, which is why `validate/1` alone lets it
      # past and the resolution is what refuses it.
      assert {:ok, %URI{}} = Url.validate("http://localhost/f")
      assert {:error, reason} = Url.resolve("localhost")
      assert reason =~ "loopback"
      assert {:error, _} = Url.check_saveable("http://localhost/f")
    end

    test "a name that does not resolve is refused at request time" do
      assert {:error, "does not resolve"} =
               Url.resolve("no-such-host.invalid.fountain-test")
    end

    test "a name that does not resolve is still saveable" do
      # A receiver that is not deployed yet is an ordinary thing to save. The
      # request-time check is the authoritative one.
      assert {:ok, %URI{}} =
               Url.check_saveable("https://no-such-host.invalid.fountain-test/f")
    end

    test "a literal public address resolves to itself without DNS" do
      assert {:ok, [{93, 184, 216, 34}]} = Url.resolve("93.184.216.34")
    end
  end

  describe "pinning" do
    test "the request goes to the checked address, carrying the original host" do
      assert {:ok, pinned} = Url.pin("https://93.184.216.34/hooks/f")
      assert pinned.host == "93.184.216.34"
      assert pinned.url == "https://93.184.216.34/hooks/f"
      assert pinned.address == {93, 184, 216, 34}
    end

    test "the port and path survive pinning" do
      assert {:ok, pinned} = Url.pin("http://93.184.216.34:8443/a/b?c=d")
      assert pinned.url == "http://93.184.216.34:8443/a/b?c=d"
    end

    test "a blocked target never produces a pinned request" do
      assert {:error, _} = Url.pin("http://127.0.0.1/f")
      assert {:error, _} = Url.pin("http://localhost/f")
    end

    test "a host that stopped resolving does not fall back to an unchecked request" do
      assert {:error, "does not resolve"} =
               Url.pin("https://no-such-host.invalid.fountain-test/f")
    end
  end
end

defmodule Fountain.Webhooks.UrlHttpFlagTest do
  @moduledoc """
  The one case that has to flip a global: `webhook_allow_http` is application
  env, so a test that changes it cannot be `async: true` beside tests that
  read it. A sync module runs after every async one, which is what keeps this
  from poisoning `Fountain.Webhooks.UrlTest`.
  """

  use ExUnit.Case, async: false

  alias Fountain.Webhooks.Url

  setup do
    original = Application.get_env(:fountain, :webhook_allow_http)
    Application.put_env(:fountain, :webhook_allow_http, false)
    on_exit(fn -> Application.put_env(:fountain, :webhook_allow_http, original) end)
    :ok
  end

  test "with the flag off, http is refused and https still passes" do
    assert {:error, "must use https"} = Url.validate("http://hooks.example.com/f")
    assert {:ok, _} = Url.validate("https://hooks.example.com/f")
  end

  test "the flag relaxes the scheme and nothing else" do
    Application.put_env(:fountain, :webhook_allow_http, true)

    assert {:ok, _} = Url.validate("http://hooks.example.com/f")
    # Still refused: the flag is about the scheme, not about the target.
    assert {:error, _} = Url.validate("http://127.0.0.1/f")
    assert {:error, _} = Url.validate("http://169.254.169.254/f")
  end
end
