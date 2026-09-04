defmodule Fountain.BrokerProxyRig do
  @moduledoc """
  A real proxy, a real origin and a sandbox-shaped client, for the handful
  of broker tests that have to see bytes rather than a synthesised
  telemetry event.

  `Fountain.Broker.Native`'s unit tests execute
  `[:managoat, :broker, :request]` themselves, which is the right shape for
  asserting what the handler does with an event. It cannot answer the other
  question ADR 0019 and #1501 ask: *does the library actually emit what we
  are relying on it to emit?* A row like "the query string never reaches
  `broker_requests.path`" is a claim about `managoat_broker`'s behaviour
  that Fountain stores the consequences of, and reading it out of a
  changelog is not a test.

  So this rig drives the real listener, with Fountain's own
  `Fountain.Broker.Native.Sessions` store and
  `Fountain.Broker.Native.attach_telemetry/0` handler, over a real
  `CONNECT` tunnel to a real TLS origin, and lets a test look at the row.

  Two things differ from production, both because the origin is local:
  `allow_private_upstreams: true` (the SSRF guard would refuse loopback)
  and `upstream_ssl_options` trusting the origin's throwaway CA. Neither
  touches the paths under test.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised!: 2]

  alias Fountain.Broker
  alias Fountain.Broker.Native

  defmodule Origin do
    @moduledoc false
    # Echoes what it was actually sent, so a test can tell the difference
    # between "the proxy logged a path" and "the origin received a target".
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
          query: conn.query_string,
          headers: Map.new(conn.req_headers),
          body: body
        })
      )
    end
  end

  @doc """
  The whole rig: a TLS origin on loopback, the request-log writer, the
  telemetry handler and a listener on port 0 that trusts the origin.

  Returns `%{proxy_port:, origin_port:, origin_host:, log:}`. The caller is
  responsible for `Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})`
  — the proxy answers on its own processes.
  """
  def start(opts \\ []) do
    {origin_ca, tls} = origin_tls()
    origin_port = start_https_origin(tls)

    log = start_supervised!(Fountain.Broker.Native.RequestLog)
    Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, self(), log)
    :ok = Native.attach_telemetry()

    {Managoat.Broker, listener_opts} = Native.listener_spec()

    start_supervised!(
      {Managoat.Broker,
       listener_opts
       |> Keyword.merge(
         port: 0,
         allow_private_upstreams: true,
         upstream_ssl_options: [cacerts: [X509.Certificate.to_der(origin_ca)]]
       )
       |> Keyword.merge(Keyword.take(opts, [:max_request_bytes, :request_read_timeout]))}
    )

    %{
      proxy_port: Managoat.Broker.port(),
      origin_port: origin_port,
      origin_host: "localhost:#{origin_port}",
      log: log
    }
  end

  @doc "Flush the request-log buffer and return the conversation's rows, newest first."
  def rows(rig, conversation_id) do
    :ok = Fountain.Broker.Native.RequestLog.flush(rig.log)
    {:ok, %{events: events}} = Broker.request_log(conversation_id)
    events
  end

  @doc """
  A tunnel as a brokered sandbox opens one: `CONNECT` with the session's own
  proxy credential, then TLS trusting the broker CA.
  """
  def tunnel(rig, session) do
    [{"HTTPS_PROXY", url} | _] = Broker.sandbox_env(session)
    %URI{userinfo: userinfo} = URI.parse(url)

    {:ok, tcp} =
      :gen_tcp.connect(~c"127.0.0.1", rig.proxy_port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        tcp,
        "CONNECT #{rig.origin_host} HTTP/1.1\r\nHost: #{rig.origin_host}\r\n" <>
          "Proxy-Authorization: Basic #{Base.encode64(userinfo)}\r\n\r\n"
      )

    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)

    unless reply =~ "HTTP/1.1 200" do
      raise "CONNECT #{rig.origin_host} answered #{inspect(reply)}"
    end

    {:ok, tls} =
      :ssl.connect(
        tcp,
        [
          verify: :verify_peer,
          cacerts: broker_ca_ders(),
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

  @doc "Send one origin-form request down the tunnel; returns the origin's decoded echo."
  def request(tls, raw) do
    :ok = :ssl.send(tls, raw)
    read_json(tls, "")
  end

  @doc """
  One absolute-form plain request straight at the proxy, no tunnel. Returns
  the origin's decoded echo. The plain path only reaches a plain origin, so
  this takes an explicit `http://` target.
  """
  def plain_request(rig, session, target, host) do
    [{"HTTPS_PROXY", url} | _] = Broker.sandbox_env(session)
    %URI{userinfo: userinfo} = URI.parse(url)

    {:ok, tcp} =
      :gen_tcp.connect(~c"127.0.0.1", rig.proxy_port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        tcp,
        "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n" <>
          "Proxy-Authorization: Basic #{Base.encode64(userinfo)}\r\nConnection: close\r\n\r\n"
      )

    read_plain_json(tcp, "")
  end

  @doc "Start a plain HTTP origin on 127.0.0.1:0; returns its port."
  def start_http_origin do
    pid =
      start_supervised!(
        {Bandit, plug: Origin, scheme: :http, port: 0, ip: {127, 0, 0, 1}},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # ---------------------------------------------------------------------------

  defp broker_ca_ders do
    {:ok, pem} = Broker.ca_pem()
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
  end

  defp origin_tls do
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "/CN=Broker Rig Origin CA", template: :root_ca)
    key = X509.PrivateKey.new_ec(:secp256r1)

    sans =
      X509.Certificate.Extension.subject_alt_name(
        dNSName: "localhost",
        iPAddress: <<127, 0, 0, 1>>
      )

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=localhost", ca, ca_key, extensions: [subject_alt_name: sans])

    {ca, [cert: X509.Certificate.to_der(cert), key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}]}
  end

  defp start_https_origin(tls) do
    pid =
      start_supervised!(
        {Bandit,
         plug: Origin,
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         thousand_island_options: [transport_options: tls]},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp read_json(tls, acc) do
    case framed(acc) do
      {:ok, body} -> Jason.decode!(body)
      :more -> with {:ok, data} <- :ssl.recv(tls, 0, 5_000), do: read_json(tls, acc <> data)
    end
  end

  defp read_plain_json(tcp, acc) do
    case framed(acc) do
      {:ok, body} ->
        Jason.decode!(body)

      :more ->
        with {:ok, data} <- :gen_tcp.recv(tcp, 0, 5_000), do: read_plain_json(tcp, acc <> data)
    end
  end

  defp framed(acc) do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, len] <- Regex.run(~r/content-length: (\d+)/i, head),
         len = String.to_integer(len),
         true <- byte_size(body) >= len do
      {:ok, binary_part(body, 0, len)}
    else
      _ -> :more
    end
  end
end
