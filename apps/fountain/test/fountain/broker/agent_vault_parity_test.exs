defmodule Fountain.Broker.AgentVaultParityTest do
  # The behaviours Fountain relied on from Agent Vault 0.39.1, replayed
  # against the native proxy. Each test names the upstream test it stands in
  # for (internal/mitm/proxy_test.go and forward_test.go in
  # Infisical/agent-vault), so a gap between the two is a missing test here,
  # not a guess. What is deliberately NOT ported is listed at the bottom.
  use Fountain.DataCase, async: false

  alias Fountain.Broker
  alias Fountain.Broker.{CA, Proxy}

  defmodule Origin do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/stream"} = conn, _opts) do
      Process.register(self(), :parity_stream_origin)
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, "data: first\n\n")
      # The second chunk waits for the test to say the first arrived.
      receive do
        :continue -> :ok
      after
        5_000 -> :ok
      end

      {:ok, conn} = chunk(conn, "data: second\n\n")
      conn
    end

    def call(%{request_path: "/ws"} = conn, _opts) do
      conn
      |> WebSockAdapter.upgrade(Fountain.Broker.AgentVaultParityTest.Echo, conn.req_headers,
        timeout: 5_000
      )
      |> halt()
    end

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{headers: Map.new(conn.req_headers), body: body, path: conn.request_path})
      )
    end
  end

  defmodule Echo do
    @moduledoc false
    # A WebSocket that answers every text frame with the authorization header
    # the upgrade request carried, then the frame.
    @behaviour WebSock

    def init(headers), do: {:ok, Map.new(headers)}

    def handle_in({text, [opcode: :text]}, headers) do
      {:reply, :ok, {:text, (headers["authorization"] || "none") <> "|" <> text}, headers}
    end

    def handle_info(_, state), do: {:ok, state}
    def terminate(_, _), do: :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
    previous = Application.get_env(:fountain, :broker_allow_private_upstreams)
    Application.put_env(:fountain, :broker_allow_private_upstreams, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fountain, :broker_allow_private_upstreams),
        else: Application.put_env(:fountain, :broker_allow_private_upstreams, previous)
    end)

    {origin_ca, tls} = origin_tls()
    {_untrusted_ca, untrusted_tls} = origin_tls()

    https = start_origin(:https_origin, tls)
    untrusted = start_origin(:untrusted_origin, untrusted_tls)

    start_supervised!(
      {Broker.Supervisor,
       port: 0, upstream_ssl_options: [cacerts: [X509.Certificate.to_der(origin_ca)]]}
    )

    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, %{token: token, vault: vault}} =
      Broker.Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        vault: Broker.vault_name(conv.id),
        credentials: %{"KEY" => "real-secret"},
        services: [
          %{
            "name" => "origin",
            "host" => "localhost",
            "auth" => %{"type" => "bearer", "token" => "KEY"}
          }
        ],
        unmatched_host_policy: "passthrough",
        ttl_seconds: 600
      })

    {:ok,
     proxy_port: Proxy.port(),
     https_port: https,
     untrusted_port: untrusted,
     token: token,
     vault: vault,
     conv: conv}
  end

  defp origin_tls do
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "/CN=Origin CA", template: :root_ca)
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=localhost", ca, ca_key,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])]
      )

    {ca,
     [
       cert: X509.Certificate.to_der(cert),
       key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}
     ]}
  end

  defp start_origin(id, tls) do
    pid =
      start_supervised!(
        {Bandit,
         plug: Origin,
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         thousand_island_options: [transport_options: tls]},
        id: id
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp proxy_auth(ctx), do: "Basic " <> Base.encode64(ctx.token <> ":" <> ctx.vault)

  defp connect(ctx, port) do
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        tcp,
        "CONNECT localhost:#{port} HTTP/1.1\r\nHost: localhost:#{port}\r\n" <>
          "Proxy-Authorization: #{proxy_auth(ctx)}\r\n\r\n"
      )

    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
    {tcp, reply}
  end

  defp tunnel(ctx) do
    {tcp, reply} = connect(ctx, ctx.https_port)
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

  defp read_json(tls, acc \\ "") do
    {:ok, data} = :ssl.recv(tls, 0, 5_000)
    acc = acc <> data

    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, len] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(len) do
      Jason.decode!(binary_part(body, 0, String.to_integer(len)))
    else
      _ -> read_json(tls, acc)
    end
  end

  # TestMITMInjectsCredentials
  test "the credential is attached where the client sent a placeholder", ctx do
    tls = tunnel(ctx)

    :ok =
      :ssl.send(
        tls,
        "GET /a HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer __key__\r\n\r\n"
      )

    assert %{"headers" => %{"authorization" => "Bearer real-secret"}} = read_json(tls)
  end

  # TestMITMForwardStripsHopByHopHeaders / TestMITMBearerForwardsArbitraryClientHeaders
  test "proxy headers are stripped; every other client header is forwarded", ctx do
    tls = tunnel(ctx)

    :ok =
      :ssl.send(
        tls,
        "GET /h HTTP/1.1\r\nHost: localhost\r\nProxy-Authorization: Basic leak\r\n" <>
          "Proxy-Connection: keep-alive\r\nX-Custom: yes\r\nUser-Agent: sandbox/1\r\n\r\n"
      )

    %{"headers" => headers} = read_json(tls)
    refute Map.has_key?(headers, "proxy-authorization")
    refute Map.has_key?(headers, "proxy-connection")
    assert headers["x-custom"] == "yes"
    assert headers["user-agent"] == "sandbox/1"
  end

  # TestMITMForwardKeepalivePersistsAcrossRequests
  test "keep-alive: the injection happens on every request of a tunnel", ctx do
    tls = tunnel(ctx)

    for n <- 1..3 do
      :ok = :ssl.send(tls, "GET /#{n} HTTP/1.1\r\nHost: localhost\r\n\r\n")
      path = "/#{n}"

      assert %{"path" => ^path, "headers" => %{"authorization" => "Bearer real-secret"}} =
               read_json(tls)
    end
  end

  # TestMITMForwardStreamsChunksPromptly
  test "a streaming response is relayed chunk by chunk, not buffered to the end", ctx do
    tls = tunnel(ctx)
    :ok = :ssl.send(tls, "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")

    first = recv_until(tls, "data: first")
    refute first =~ "data: second"

    # Release the origin's second chunk and see it arrive.
    send(:parity_stream_origin, :continue)

    assert recv_until(tls, "data: second") =~ "data: second"
  end

  defp recv_until(tls, needle, acc \\ "") do
    if String.contains?(acc, needle) do
      acc
    else
      {:ok, data} = :ssl.recv(tls, 0, 5_000)
      recv_until(tls, needle, acc <> data)
    end
  end

  # TestMITMUpstreamCertUntrusted
  test "an origin whose certificate is not trusted is a 502, and no tunnel opens", ctx do
    {_tcp, reply} = connect(ctx, ctx.untrusted_port)
    assert reply =~ "HTTP/1.1 502"
  end

  # TestMITMPassthroughForwardsClientAuthorization
  test "an unmatched host keeps the client's own authorization header", ctx do
    Fountain.Repo.update_all(Fountain.Broker.Session, set: [services: []])
    tls = tunnel(ctx)

    :ok =
      :ssl.send(tls, "GET /p HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer mine\r\n\r\n")

    assert %{"headers" => %{"authorization" => "Bearer mine"}} = read_json(tls)
  end

  # TestMITMUnknownHostInTunnel (deny mode)
  test "deny: an unmatched host is 403 inside the tunnel", ctx do
    # A rule for one path of the host lets the tunnel open; the request
    # below is to another path, so it is unmatched inside the tunnel.
    Fountain.Repo.update_all(Fountain.Broker.Session,
      set: [
        services: [
          %{
            "name" => "narrow",
            "host" => "localhost/allowed/*",
            "auth" => %{"type" => "passthrough"}
          }
        ],
        unmatched_host_policy: "deny"
      ]
    )

    tls = tunnel(ctx)
    :ok = :ssl.send(tls, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    {:ok, reply} = :ssl.recv(tls, 0, 5_000)
    assert reply =~ "HTTP/1.1 403"
  end

  # Beyond Agent Vault, for gate 2: under deny a host no rule names is
  # refused at CONNECT, so no tunnel and no TLS handshake happen for it.
  test "deny: a host no service names is 403 at CONNECT", ctx do
    Fountain.Repo.update_all(Fountain.Broker.Session,
      set: [
        services: [
          %{"name" => "x", "host" => "api.example.com", "auth" => %{"type" => "passthrough"}}
        ],
        unmatched_host_policy: "deny"
      ]
    )

    {_tcp, reply} = connect(ctx, ctx.https_port)
    assert reply =~ "HTTP/1.1 403"
  end

  # TestMITMMissingProxyAuth / TestMITMInvalidSession / TestMITMVaultHintMismatch
  test "no token, a bad token and a wrong vault are refused with 407", ctx do
    for auth <- [
          nil,
          "Basic " <> Base.encode64("fb_bad:" <> ctx.vault),
          "Basic " <> Base.encode64(ctx.token <> ":c-other")
        ] do
      {:ok, tcp} =
        :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false], 5_000)

      line = if auth, do: "Proxy-Authorization: #{auth}\r\n", else: ""
      :ok = :gen_tcp.send(tcp, "CONNECT localhost:#{ctx.https_port} HTTP/1.1\r\n#{line}\r\n")
      {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
      assert reply =~ "HTTP/1.1 407"
    end
  end

  # TestMITMWebSocketInjectsCredentialsAndPipesFrames (the header half: the
  # upgrade request is injected like any other; frames are piped as bytes,
  # never rewritten — see the list at the bottom)
  test "a WebSocket upgrade through the tunnel carries the injected header, and frames flow",
       ctx do
    tls = tunnel(ctx)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :ssl.send(
        tls,
        "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer __key__\r\n\r\n"
      )

    {:ok, reply} = :ssl.recv(tls, 0, 5_000)
    assert reply =~ "HTTP/1.1 101"

    # One masked text frame: "hi".
    mask = <<1, 2, 3, 4>>
    payload = :crypto.exor("hi", binary_part(mask, 0, 2))
    :ok = :ssl.send(tls, <<0x81, 0x82>> <> mask <> payload)

    {:ok, frame} = :ssl.recv(tls, 0, 5_000)
    <<0x81, len, text::binary-size(len)>> = frame
    assert text == "Bearer real-secret|hi"
  end

  # Not ported, on purpose:
  # - TestMITMSubstitution* (placeholder rewriting in path, query and
  #   arbitrary headers): the native broker injects auth headers only; the
  #   one catalog preset that needs it (telegram) is marked unusable.
  # - TestCopyWSFrames* (credential substitution inside WebSocket frames).
  # - TestMITM*RateLimit* (auth-failure rate limiting on the proxy port).
  # - TestResponseLimit* / TestRequestBodyCap* (body size caps; Agent Vault's
  #   response cap was unlimited by default too).
  # - TestMITMForwardIPv6PreservesHostHeader: the proxy resolves IPv4 only.
  # - TestMITMPortBasedRouting, TestMITMAmbiguousAgentVault: Agent Vault's
  #   multi-vault selection, which a per-conversation token makes moot.
end
