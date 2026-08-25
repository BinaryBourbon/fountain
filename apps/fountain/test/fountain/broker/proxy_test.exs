defmodule Fountain.Broker.ProxyTest do
  # The proxy end to end: a sandbox-shaped client dials the listener with a
  # session token, tunnels TLS to an origin, and the origin sees the real
  # credential where the client sent a placeholder.
  use Fountain.DataCase, async: false

  alias Fountain.Broker
  alias Fountain.Broker.{CA, Proxy}

  defmodule Origin do
    @moduledoc false
    # Echoes the request it saw, so the test can look at the headers the
    # proxy forwarded.
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          method: conn.method,
          path: conn.request_path,
          headers: Map.new(conn.req_headers),
          body: body
        })
      )
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    # The origins below are on localhost, which the SSRF guard refuses.
    previous = Application.get_env(:fountain, :broker_allow_private_upstreams)
    Application.put_env(:fountain, :broker_allow_private_upstreams, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fountain, :broker_allow_private_upstreams),
        else: Application.put_env(:fountain, :broker_allow_private_upstreams, previous)
    end)

    # An origin with its own CA, which only the proxy is told to trust.
    origin_ca_key = X509.PrivateKey.new_ec(:secp256r1)

    origin_ca =
      X509.Certificate.self_signed(origin_ca_key, "/CN=Origin Test CA", template: :root_ca)

    origin_key = X509.PrivateKey.new_ec(:secp256r1)

    origin_cert =
      origin_key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=localhost", origin_ca, origin_ca_key,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])]
      )

    tls = [
      cert: X509.Certificate.to_der(origin_cert),
      key: {:ECPrivateKey, X509.PrivateKey.to_der(origin_key)}
    ]

    https =
      start_supervised!(
        {Bandit,
         plug: Origin,
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         thousand_island_options: [transport_options: tls]},
        id: :https_origin
      )

    http =
      start_supervised!({Bandit, plug: Origin, scheme: :http, port: 0, ip: {127, 0, 0, 1}},
        id: :http_origin
      )

    {:ok, {_, https_port}} = ThousandIsland.listener_info(https)
    {:ok, {_, http_port}} = ThousandIsland.listener_info(http)

    start_supervised!(
      {Broker.Supervisor,
       port: 0, upstream_ssl_options: [cacerts: [X509.Certificate.to_der(origin_ca)]]}
    )

    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, %{token: token, vault: vault}} =
      Fountain.Broker.Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        vault: Broker.vault_name(conv.id),
        credentials: %{"GITHUB_TOKEN" => "ghp_real", "USER" => "x-access-token"},
        services: [
          %{
            "name" => "origin",
            "host" => "localhost",
            "auth" => %{"type" => "bearer", "token" => "GITHUB_TOKEN"}
          }
        ],
        unmatched_host_policy: "passthrough",
        ttl_seconds: 600
      })

    {:ok,
     proxy_port: Proxy.port(),
     https_port: https_port,
     http_port: http_port,
     token: token,
     vault: vault,
     user: user,
     conv: conv}
  end

  defp proxy_auth(token, vault), do: "Basic " <> Base.encode64(token <> ":" <> vault)

  defp connect(ctx, host_port, auth) do
    {:ok, tcp} =
      :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        tcp,
        "CONNECT #{host_port} HTTP/1.1\r\nHost: #{host_port}\r\nProxy-Authorization: #{auth}\r\n\r\n"
      )

    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
    {tcp, reply}
  end

  # A tunnel as the sandbox sees it: CONNECT, then TLS trusting the broker CA.
  defp tunnel(ctx, host_port \\ nil) do
    host_port = host_port || "localhost:#{ctx.https_port}"
    {tcp, reply} = connect(ctx, host_port, proxy_auth(ctx.token, ctx.vault))
    assert reply =~ "HTTP/1.1 200"

    {:ok, tls} =
      :ssl.connect(
        tcp,
        [
          verify: :verify_peer,
          cacerts: [CA.der()],
          server_name_indication: ~c"localhost",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          active: false
        ],
        5_000
      )

    tls
  end

  defp request(tls, raw) do
    :ok = :ssl.send(tls, raw)
    read_response(tls, "")
  end

  defp read_response(tls, acc) do
    {:ok, data} = :ssl.recv(tls, 0, 5_000)
    acc = acc <> data

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, len] = Regex.run(~r/content-length: (\d+)/i, head)
        len = String.to_integer(len)

        if byte_size(body) >= len,
          do: {head, Jason.decode!(binary_part(body, 0, len))},
          else: read_response(tls, acc)

      _ ->
        read_response(tls, acc)
    end
  end

  test "the origin sees the real credential where the sandbox sent a placeholder", ctx do
    tls = tunnel(ctx)

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
    tls = tunnel(ctx)

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
    tls = tunnel(ctx)
    :ok = :ssl.send(tls, "POST /p HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n0123")
    Process.sleep(50)
    :ok = :ssl.send(tls, "456789")
    {_, echoed} = read_response(tls, "")
    assert echoed["body"] == "0123456789"
  end

  test "a wrong token, a wrong vault, and no token are all 407", ctx do
    for auth <- [
          proxy_auth("fb_nope", ctx.vault),
          proxy_auth(ctx.token, "c-other"),
          "Basic " <> Base.encode64("garbage")
        ] do
      {_tcp, reply} = connect(ctx, "localhost:#{ctx.https_port}", auth)
      assert reply =~ "HTTP/1.1 407"
      assert reply =~ ~r/proxy-authenticate: Basic/i
    end

    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false])
    :ok = :gen_tcp.send(tcp, "CONNECT localhost:443 HTTP/1.1\r\n\r\n")
    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
    assert reply =~ "HTTP/1.1 407"
  end

  test "an origin the proxy cannot reach is a 502 before any tunnel exists", ctx do
    {_tcp, reply} = connect(ctx, "localhost:1", proxy_auth(ctx.token, ctx.vault))
    assert reply =~ "HTTP/1.1 502"
  end

  test "an origin on a private or loopback address is refused before any connection", ctx do
    Application.put_env(:fountain, :broker_allow_private_upstreams, false)

    {_tcp, reply} = connect(ctx, "localhost:#{ctx.https_port}", proxy_auth(ctx.token, ctx.vault))
    assert reply =~ "HTTP/1.1 403"

    for ip <- [{10, 1, 2, 3}, {172, 16, 0, 1}, {192, 168, 1, 1}, {169, 254, 169, 254}, {127, 0, 0, 1}],
        do: assert(Fountain.Broker.Proxy.private?(ip))

    for ip <- [{140, 82, 112, 3}, {172, 32, 0, 1}, {8, 8, 8, 8}],
        do: refute(Fountain.Broker.Proxy.private?(ip))
  end

  test "a passthrough host is forwarded untouched", ctx do
    # Bind the session to a host that is not the one dialled: nothing matches.
    Fountain.Repo.update_all(Fountain.Broker.Session, set: [services: []])
    tls = tunnel(ctx)

    {_, echoed} =
      request(
        tls,
        "GET /x HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer __github_token__\r\n\r\n"
      )

    assert echoed["headers"]["authorization"] == "Bearer __github_token__"
  end

  test "a denied host is 403 inside the tunnel", ctx do
    Fountain.Repo.update_all(Fountain.Broker.Session,
      set: [services: [], unmatched_host_policy: "deny"]
    )

    tls = tunnel(ctx)
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
          "Proxy-Authorization: #{proxy_auth(ctx.token, ctx.vault)}\r\n" <>
          "Authorization: Bearer __github_token__\r\n\r\n"
      )

    reply = read_until_closed(tcp, "")
    assert reply =~ "HTTP/1.1 200"
    [_, body] = String.split(reply, "\r\n\r\n", parts: 2)
    echoed = Jason.decode!(body)
    assert echoed["path"] == "/plain"
    assert echoed["headers"]["authorization"] == "Bearer ghp_real"
    refute Map.has_key?(echoed["headers"], "proxy-authorization")
  end

  test "the request log names the conversation, never a header", ctx do
    :telemetry.attach(
      "proxy-test",
      [:fountain, :broker, :request],
      fn _e, _m, meta, pid -> send(pid, {:request, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("proxy-test") end)

    tls = tunnel(ctx)
    request(tls, "GET /logged HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer x\r\n\r\n")

    conv_id = ctx.conv.id

    assert_receive {:request,
                    %{
                      conversation_id: ^conv_id,
                      host: "localhost",
                      path: "/logged",
                      outcome: "origin"
                    } = meta}

    refute Map.has_key?(meta, :headers)
  end

  defp read_until_closed(tcp, acc) do
    case :gen_tcp.recv(tcp, 0, 5_000) do
      {:ok, data} -> read_until_closed(tcp, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
