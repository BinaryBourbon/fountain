defmodule Managoat.Broker.ProxyTest do
  # The proxy end to end: a sandbox-shaped client dials the listener with a
  # session token, tunnels TLS to an origin, and the origin sees the real
  # credential where the client sent a placeholder.
  use Managoat.Broker.ProxyCase, async: true

  alias Managoat.Broker.Proxy

  setup do
    ctx = start_rig()

    session = %Session{
      rules: [
        %Rule{name: "origin", pattern: "localhost", scheme: :bearer, credential: "ghp_real"}
      ],
      unmatched_host_policy: :passthrough,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      meta: %{conversation_id: "conv-1", user_id: "user-1"}
    }

    Map.merge(ctx, %{token: put_session(ctx, session), session: session})
  end

  test "the origin sees the real credential where the sandbox sent a placeholder", ctx do
    tls = tunnel(ctx, ctx.token)

    {head, echoed} =
      request(
        tls,
        "GET /repos HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer __github_token__\r\n\r\n"
      )

    assert head =~ "HTTP/1.1 200"
    assert echoed["path"] == "/repos"
    assert echoed["headers"]["authorization"] == "Bearer ghp_real"
    refute Map.has_key?(echoed["headers"], "proxy-authorization")
  end

  test "several requests ride one tunnel, bodies included", ctx do
    tls = tunnel(ctx, ctx.token)

    {_, first} = request(tls, "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert first["path"] == "/a"
    assert first["headers"]["authorization"] == "Bearer ghp_real"

    {_, second} =
      request(
        tls,
        "POST /b HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
      )

    assert second["method"] == "POST"
    assert second["body"] == "hello"

    {_, third} =
      request(
        tls,
        "POST /c HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
      )

    assert third["body"] == "abcde"
  end

  test "a request body that arrives in pieces is copied whole", ctx do
    tls = tunnel(ctx, ctx.token)
    :ok = :ssl.send(tls, "POST /p HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n0123")
    Process.sleep(50)
    :ok = :ssl.send(tls, "456789")
    {_, echoed} = read_response(tls, "")
    assert echoed["body"] == "0123456789"
  end

  test "a request head that arrives in pieces is parsed whole", ctx do
    tls = tunnel(ctx, ctx.token)
    :ok = :ssl.send(tls, "GET /split HTTP/1.1\r\nHost: loc")
    Process.sleep(50)
    :ok = :ssl.send(tls, "alhost\r\n\r\n")
    {_, echoed} = read_response(tls, "")
    assert echoed["path"] == "/split"
  end

  test "a wrong token, an expired session, garbage and no token are all 407", ctx do
    expired = %{ctx.session | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    expired_token = put_session(ctx, expired)

    for auth <- [
          proxy_auth("mb_nope"),
          proxy_auth(expired_token),
          "Basic " <> Base.encode64("garbage"),
          "Basic not-base64!",
          "Bearer #{ctx.token}",
          nil
        ] do
      {_tcp, reply} = connect(ctx, "localhost:#{ctx.https_port}", auth)
      assert reply =~ "HTTP/1.1 407", "#{inspect(auth)} was not refused"
      assert reply =~ ~r/proxy-authenticate: Basic/i
    end
  end

  test "the label half of the proxy credential is not checked: the token is the binding", ctx do
    {_tcp, reply} = connect(ctx, "localhost:#{ctx.https_port}", proxy_auth(ctx.token, "other"))
    assert reply =~ "HTTP/1.1 200"
  end

  test "an origin the proxy cannot reach is a 502 before any tunnel exists", ctx do
    {_tcp, reply} = connect(ctx, "localhost:1", proxy_auth(ctx.token))
    assert reply =~ "HTTP/1.1 502"
  end

  test "a host that does not resolve is a 502", ctx do
    {_tcp, reply} = connect(ctx, "no-such-host.invalid:443", proxy_auth(ctx.token))
    assert reply =~ "HTTP/1.1 502"
  end

  test "a bad request line and a bad CONNECT authority are 400", ctx do
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false])
    :ok = :gen_tcp.send(tcp, "\x16\x03\x01 not http\r\n\r\n")
    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
    assert reply =~ "HTTP/1.1 400"

    {_tcp, reply} = connect(ctx, "nope", proxy_auth(ctx.token))
    assert reply =~ "HTTP/1.1 400"
  end

  test "an origin on a private or loopback address is refused before any connection" do
    ctx = start_rig(allow_private_upstreams: false)
    token = put_session(ctx, bearer_session("x"))

    {_tcp, reply} = connect(ctx, "localhost:#{ctx.https_port}", proxy_auth(token))
    assert reply =~ "HTTP/1.1 403"

    for ip <- [
          {10, 1, 2, 3},
          {172, 16, 0, 1},
          {192, 168, 1, 1},
          {169, 254, 169, 254},
          {100, 64, 0, 1},
          {127, 0, 0, 1},
          {0, 0, 0, 0}
        ],
        do: assert(Proxy.private?(ip))

    for ip <- [{140, 82, 112, 3}, {172, 32, 0, 1}, {100, 128, 0, 1}, {8, 8, 8, 8}],
        do: refute(Proxy.private?(ip))
  end

  test "a passthrough host is forwarded untouched", ctx do
    # A session whose rules name another host: nothing matches localhost.
    Memory.put(ctx.store, ctx.token, %{ctx.session | rules: []})
    tls = tunnel(ctx, ctx.token)

    {_, echoed} =
      request(
        tls,
        "GET /x HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer __github_token__\r\n\r\n"
      )

    assert echoed["headers"]["authorization"] == "Bearer __github_token__"
  end

  test "a denied host is 403 inside the tunnel", ctx do
    # A rule for one path of the host lets the tunnel open; the request
    # below is to another path, so it is unmatched inside the tunnel.
    Memory.put(ctx.store, ctx.token, %{
      ctx.session
      | rules: [%Rule{name: "narrow", pattern: "localhost/allowed/*", scheme: :passthrough}],
        unmatched_host_policy: :deny
    })

    tls = tunnel(ctx, ctx.token)
    :ok = :ssl.send(tls, "GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
    {:ok, reply} = :ssl.recv(tls, 0, 5_000)
    assert reply =~ "HTTP/1.1 403"
  end

  test "plain HTTP in absolute form is forwarded with the credential attached", ctx do
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        tcp,
        "GET http://localhost:#{ctx.http_port}/plain?q=1 HTTP/1.1\r\nHost: localhost\r\n" <>
          "Proxy-Authorization: #{proxy_auth(ctx.token)}\r\n" <>
          "Authorization: Bearer __github_token__\r\n\r\n"
      )

    reply = read_until_closed(tcp)
    assert reply =~ "HTTP/1.1 200"
    [_, body] = String.split(reply, "\r\n\r\n", parts: 2)
    echoed = Jason.decode!(body)
    assert echoed["path"] == "/plain"
    assert echoed["headers"]["authorization"] == "Bearer ghp_real"
    refute Map.has_key?(echoed["headers"], "proxy-authorization")
  end

  test "plain HTTP with a body is forwarded whole", ctx do
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        tcp,
        "POST http://localhost:#{ctx.http_port}/body HTTP/1.1\r\nHost: localhost\r\n" <>
          "Proxy-Authorization: #{proxy_auth(ctx.token)}\r\nContent-Length: 5\r\n\r\nhel"
      )

    Process.sleep(50)
    :ok = :gen_tcp.send(tcp, "lo")

    reply = read_until_closed(tcp)
    [_, body] = String.split(reply, "\r\n\r\n", parts: 2)
    assert Jason.decode!(body)["body"] == "hello"
  end

  test "plain HTTP under deny to an unmatched host is 403", ctx do
    Memory.put(ctx.store, ctx.token, %{ctx.session | rules: [], unmatched_host_policy: :deny})
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        tcp,
        "GET http://localhost:#{ctx.http_port}/ HTTP/1.1\r\nHost: localhost\r\n" <>
          "Proxy-Authorization: #{proxy_auth(ctx.token)}\r\n\r\n"
      )

    assert read_until_closed(tcp) =~ "HTTP/1.1 403"
  end

  test "the request log names the session's meta and the rule, never a header", ctx do
    handler = "proxy-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:managoat, :broker, :request],
      fn _e, measurements, meta, pid -> send(pid, {:request, measurements, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    tls = tunnel(ctx, ctx.token)
    request(tls, "GET /logged HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer x\r\n\r\n")

    assert_receive {:request, %{count: 1},
                    %{
                      method: "GET",
                      host: "localhost",
                      path: "/logged",
                      outcome: :injected,
                      rule: "origin",
                      meta: %{conversation_id: "conv-1", user_id: "user-1"}
                    } = meta}

    refute Map.has_key?(meta, :headers)

    # Passthrough and denied outcomes, on the same event.
    Memory.put(ctx.store, ctx.token, %{ctx.session | rules: []})
    tls = tunnel(ctx, ctx.token)
    request(tls, "GET /through HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:request, _, %{path: "/through", outcome: :passthrough, rule: nil}}

    Memory.put(ctx.store, ctx.token, %{
      ctx.session
      | rules: [%Rule{name: "n", pattern: "localhost/ok", scheme: :passthrough}],
        unmatched_host_policy: :deny
    })

    tls = tunnel(ctx, ctx.token)
    :ok = :ssl.send(tls, "GET /no HTTP/1.1\r\nHost: localhost\r\n\r\n")
    {:ok, _} = :ssl.recv(tls, 0, 5_000)
    assert_receive {:request, _, %{path: "/no", outcome: :denied, rule: nil}}
  end
end
