defmodule Managoat.Broker.ProxyCase do
  @moduledoc """
  The rig the end-to-end proxy tests share: a real Bandit HTTPS origin under
  its own CA (which only the proxy is told to trust), a listener on port 0
  with an in-memory store, and a sandbox-shaped client that `CONNECT`s,
  trusts the broker CA and speaks HTTP/1.1 by hand inside the tunnel.

  Everything is per test: distinct listener name, own store, own origins,
  so the modules that use this run `async: true`.
  """

  use ExUnit.CaseTemplate

  alias Managoat.Broker.{CA, Rule, Session}
  alias Managoat.Broker.Store.Memory

  using do
    quote do
      import Managoat.Broker.ProxyCase
      alias Managoat.Broker.{Rule, Session}
      alias Managoat.Broker.Store.Memory
    end
  end

  defmodule Origin do
    @moduledoc false
    # Echoes the request it saw, so a test can look at the headers the proxy
    # forwarded. `/stream` answers in two chunks, the second on demand;
    # `/ws` upgrades to a WebSocket that echoes the upgrade's auth header.
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/stream"} = conn, _opts) do
      [name] = get_req_header(conn, "x-stream-name")
      Process.register(self(), String.to_atom(name))
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, "data: first\n\n")

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
      |> WebSockAdapter.upgrade(Managoat.Broker.ProxyCase.Echo, conn.req_headers, timeout: 5_000)
      |> halt()
    end

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

  @doc "A fresh 32-byte CA seed."
  def seed, do: :crypto.strong_rand_bytes(32)

  @doc "A CA and a leaf for `localhost` signed by it, as Bandit's `transport_options`."
  def origin_tls do
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "/CN=Origin CA", template: :root_ca)
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=localhost", ca, ca_key,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])]
      )

    {ca, [cert: X509.Certificate.to_der(cert), key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}]}
  end

  @doc "Start an HTTPS origin on 127.0.0.1:0 with `tls`; returns its port."
  def start_https_origin(tls) do
    pid =
      ExUnit.Callbacks.start_supervised!(
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

  @doc "Start a plain HTTP origin on 127.0.0.1:0; returns its port."
  def start_http_origin do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: Origin, scheme: :http, port: 0, ip: {127, 0, 0, 1}},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc """
  The whole rig: an HTTPS origin, a second one under a CA the proxy does not
  trust, a plain HTTP origin, a store, and a listener on port 0 that trusts
  the first origin's CA and may dial localhost. Returns the context the
  tests read.
  """
  def start_rig(opts \\ []) do
    {origin_ca, tls} = origin_tls()
    {_untrusted_ca, untrusted_tls} = origin_tls()

    https_port = start_https_origin(tls)
    untrusted_port = start_https_origin(untrusted_tls)
    http_port = start_http_origin()

    store = :"store_#{System.unique_integer([:positive])}"
    name = :"broker_#{System.unique_integer([:positive])}"
    seed = seed()

    # An explicit id: `use Agent`'s child spec is keyed by the module, and a
    # test that starts a second rig would collide on it.
    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({Memory, name: store}, id: store))

    ExUnit.Callbacks.start_supervised!(
      {Managoat.Broker,
       [
         name: name,
         port: 0,
         store: {Memory, store},
         ca_seed: seed,
         allow_private_upstreams: Keyword.get(opts, :allow_private_upstreams, true),
         upstream_ssl_options: [cacerts: [X509.Certificate.to_der(origin_ca)]]
       ]}
    )

    %{
      name: name,
      store: store,
      seed: seed,
      ca_der: CA.der(seed),
      proxy_port: Managoat.Broker.port(name),
      https_port: https_port,
      untrusted_port: untrusted_port,
      http_port: http_port
    }
  end

  @doc "Put a session in the rig's store under a fresh token; returns the token."
  def put_session(ctx, %Session{} = session) do
    token = Memory.generate_token()
    Memory.put(ctx.store, token, session)
    token
  end

  @doc "A session with one bearer rule for `localhost`, carrying `credential`."
  def bearer_session(credential, meta \\ %{}) do
    %Session{
      rules: [
        %Rule{name: "origin", pattern: "localhost", scheme: :bearer, credential: credential}
      ],
      unmatched_host_policy: :passthrough,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      meta: meta
    }
  end

  @doc "The `Proxy-Authorization` value for a token and a label."
  def proxy_auth(token, label \\ "c-test"), do: "Basic " <> Base.encode64(token <> ":" <> label)

  @doc "CONNECT `host_port` through the proxy with `auth`; returns the raw socket and the reply."
  def connect(ctx, host_port, auth) do
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", ctx.proxy_port, [:binary, active: false], 5_000)

    line = if auth, do: "Proxy-Authorization: #{auth}\r\n", else: ""

    :ok =
      :gen_tcp.send(tcp, "CONNECT #{host_port} HTTP/1.1\r\nHost: #{host_port}\r\n#{line}\r\n")

    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
    {tcp, reply}
  end

  @doc "A tunnel as the sandbox sees it: CONNECT to the HTTPS origin, then TLS trusting the broker CA."
  def tunnel(ctx, token, host_port \\ nil) do
    host_port = host_port || "localhost:#{ctx.https_port}"
    {tcp, reply} = connect(ctx, host_port, proxy_auth(token))

    unless reply =~ "HTTP/1.1 200" do
      raise "CONNECT #{host_port} answered #{inspect(reply)}"
    end

    {:ok, tls} =
      :ssl.connect(
        tcp,
        [
          verify: :verify_peer,
          cacerts: [ctx.ca_der],
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

  @doc "Send `raw` down the tunnel and read one JSON response: `{head, decoded_body}`."
  def request(tls, raw) do
    :ok = :ssl.send(tls, raw)
    read_response(tls, "")
  end

  @doc "Read one `Content-Length` framed response off the tunnel."
  def read_response(tls, acc) do
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

  @doc "Read until `needle` has arrived."
  def recv_until(tls, needle, acc \\ "") do
    if String.contains?(acc, needle) do
      acc
    else
      {:ok, data} = :ssl.recv(tls, 0, 5_000)
      recv_until(tls, needle, acc <> data)
    end
  end

  @doc "Read a plain socket until the peer closes it."
  def read_until_closed(tcp, acc \\ "") do
    case :gen_tcp.recv(tcp, 0, 5_000) do
      {:ok, data} -> read_until_closed(tcp, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
