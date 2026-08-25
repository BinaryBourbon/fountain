defmodule Fountain.Broker.Proxy do
  @moduledoc """
  The egress proxy a brokered sandbox dials (ADR 0019, native broker).

  One plaintext HTTP listener (`BROKER_LISTEN_PORT`, TLS is the ingress's
  job as it was for Agent Vault) that speaks the two things a forward proxy
  speaks: `CONNECT host:443` for HTTPS, and absolute-form requests
  (`GET http://host/path`) for plain HTTP. The client authenticates with
  the session token in the proxy URL, which arrives as
  `Proxy-Authorization: Basic base64(token:vault)`.

  On `CONNECT` the proxy opens the upstream TLS connection first (a host it
  cannot reach is a `502` before the tunnel exists), answers `200`, then
  completes a TLS handshake with the *sandbox* using a leaf for that host
  signed by `Fountain.Broker.CA`, which the sandbox trusts because
  provisioning installed the root. Inside the tunnel it reads each request
  head, lets `Fountain.Broker.Injector` rewrite the headers, and forwards
  the head and body to the origin. Bytes coming back are relayed untouched
  and unparsed, so a streaming model reply streams.

  The binding a token resolves to is looked up once per client connection,
  which is the unit a sandbox's HTTP client pools on.
  """

  use ThousandIsland.Handler

  require Logger

  alias Fountain.Broker.{Certs, HTTP, Injector, Sessions}
  alias ThousandIsland.Socket

  @head_timeout 30_000
  @idle_timeout 300_000
  @connect_timeout 10_000

  @doc """
  The listener's child spec. Lives here rather than as `child_spec/1` on
  this module because ThousandIsland calls the handler's own `child_spec`
  for every accepted connection.
  """
  @spec listener_spec(keyword()) :: Supervisor.child_spec()
  def listener_spec(opts) do
    %{
      id: __MODULE__,
      start:
        {ThousandIsland, :start_link,
         [
           [
             port: Keyword.fetch!(opts, :port),
             handler_module: __MODULE__,
             handler_options: Keyword.take(opts, [:upstream_ssl_options]),
             read_timeout: @idle_timeout,
             supervisor_options: [name: __MODULE__]
           ]
         ]},
      type: :supervisor
    }
  end

  @doc "True when the listener is up on this node."
  @spec running?() :: boolean()
  def running? do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc "The port a listener started under `name` is bound to."
  @spec port(atom()) :: :inet.port_number()
  def port(name \\ __MODULE__) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(name)
    port
  end

  # ---------------------------------------------------------------------------
  # One client connection

  @impl ThousandIsland.Handler
  def handle_connection(socket, opts) do
    state = %{upstream_ssl_options: Keyword.get(opts, :upstream_ssl_options, [])}

    with {:ok, head, rest} <- read_head(socket, "", @head_timeout),
         {:ok, binding} <- authenticate(socket, head),
         {:ok, {host, port}, target} <- destination(socket, head) do
      case head.method do
        "CONNECT" -> tunnel(socket, host, port, binding, state)
        _ -> forward_plain(socket, head, rest, host, port, target, binding)
      end
    else
      {:error, :timeout} -> {:close, state}
      {:error, _} -> {:close, state}
    end
  end

  defp read_head(socket, buffer, timeout) do
    case HTTP.parse_request(buffer) do
      {:ok, head, rest} ->
        {:ok, head, rest}

      {:error, reason} ->
        reply(socket, 400, "Bad Request")
        {:error, reason}

      {:more, _} ->
        case Socket.recv(socket, 0, timeout) do
          {:ok, data} -> read_head(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp authenticate(socket, head) do
    with {:ok, token, vault} <- proxy_credentials(head.headers),
         {:ok, binding} <- Sessions.lookup(token, vault) do
      {:ok, binding}
    else
      {:error, reason} ->
        Logger.info("broker: refused connection: #{inspect(reason)}")

        reply(socket, 407, "Proxy Authentication Required", [
          {"proxy-authenticate", ~s(Basic realm="fountain-broker")}
        ])

        {:error, reason}
    end
  end

  defp proxy_credentials(headers) do
    with "Basic " <> encoded <- HTTP.header(headers, "proxy-authorization") || "",
         {:ok, pair} <- Base.decode64(String.trim(encoded)),
         [token, vault] <- String.split(pair, ":", parts: 2) do
      {:ok, token, vault}
    else
      _ -> {:error, :no_credentials}
    end
  end

  defp destination(socket, head) do
    case HTTP.destination(head) do
      {:ok, _, _} = ok ->
        ok

      {:error, :bad_target} ->
        reply(socket, 400, "Bad Request")
        {:error, :bad_target}
    end
  end

  # ---------------------------------------------------------------------------
  # CONNECT: a TLS tunnel the proxy terminates on both ends

  defp tunnel(socket, host, port, binding, state) do
    with {:ok, address} <- resolve(socket, host, port),
         {:ok, upstream} <- connect_tls(socket, address, host, port, state) do
      Socket.send(socket, "HTTP/1.1 200 Connection established\r\n\r\n")

      # The handshake runs on the raw socket: the handler is synchronous
      # from here to the end of the tunnel, so the transport switch stays
      # ours. Closing the TLS socket closes the TCP one under it, and the
      # handler's own close afterwards is a no-op on a closed port.
      case :ssl.handshake(socket.socket, client_ssl_options(host), @head_timeout) do
        {:ok, client} ->
          relay = spawn_link(fn -> pump(upstream, client) end)
          result = serve(client, upstream, host, port, binding, "")
          :ssl.close(upstream)
          Process.exit(relay, :kill)
          :ssl.close(client)
          result

        {:error, reason} ->
          Logger.info("broker: sandbox TLS handshake for #{host} failed: #{inspect(reason)}")
          :ssl.close(upstream)
          {:close, state}
      end
    else
      {:error, _} -> {:close, state}
    end
  end

  # The origin's address, vetted. A sandbox may name any host, and the proxy
  # sits on the operator's network, so a name that resolves into a private,
  # loopback or link-local range is refused before any connection exists:
  # otherwise the broker is a door from a third-party sandbox into the
  # cluster (Agent Vault had the same guard). The connection is then made
  # to the vetted address, not the name, so a rebinding DNS answer between
  # check and dial changes nothing. Off only for the test rig
  # (`:broker_allow_private_upstreams`), whose origins are on localhost.
  defp resolve(socket, host, port) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, [address | _]} ->
        if private?(address) and not private_upstreams_allowed?() do
          Logger.info("broker: refused #{host}:#{port}: resolves to #{:inet.ntoa(address)}")
          reply(socket, 403, "Forbidden")
          {:error, :private_upstream}
        else
          {:ok, address}
        end

      {:error, reason} ->
        Logger.info("broker: upstream #{host}:#{port} did not resolve: #{inspect(reason)}")
        reply(socket, 502, "Bad Gateway")
        {:error, reason}
    end
  end

  defp private_upstreams_allowed?,
    do: Application.get_env(:fountain, :broker_allow_private_upstreams, false)

  @doc false
  # RFC 1918, loopback, link-local (including the cloud metadata address),
  # CGNAT, and the unspecified address.
  @spec private?(:inet.ip4_address()) :: boolean()
  def private?({10, _, _, _}), do: true
  def private?({127, _, _, _}), do: true
  def private?({169, 254, _, _}), do: true
  def private?({172, b, _, _}) when b in 16..31, do: true
  def private?({192, 168, _, _}), do: true
  def private?({100, b, _, _}) when b in 64..127, do: true
  def private?({0, _, _, _}), do: true
  def private?(_), do: false

  defp connect_tls(socket, address, host, port, state) do
    case :ssl.connect(address, port, upstream_ssl_options(host, state), @connect_timeout) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.info("broker: upstream #{host}:#{port} unreachable: #{inspect(reason)}")
        reply(socket, 502, "Bad Gateway")
        {:error, reason}
    end
  end

  # Upstream → sandbox, byte for byte. When the origin closes, the sandbox's
  # side is closed too, which ends `serve/6`.
  defp pump(upstream, client) do
    case :ssl.recv(upstream, 0) do
      {:ok, data} ->
        case :ssl.send(client, data) do
          :ok -> pump(upstream, client)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ssl.close(client)
        :ok
    end
  end

  # Sandbox → upstream, one request at a time: head rewritten, body copied.
  defp serve(client, upstream, host, port, binding, buffer) do
    case HTTP.parse_request(buffer) do
      {:ok, head, rest} ->
        case Injector.inject(head.headers, host, port, head.target, binding) do
          {:ok, headers, service} ->
            log_request(binding, head, host, service)
            request = HTTP.encode_request(%{head | headers: headers}, head.target)

            with :ok <- :ssl.send(upstream, request),
                 {:ok, rest} <- copy_body(client, upstream, HTTP.body_framing(head), rest) do
              serve(client, upstream, host, port, binding, rest)
            else
              {:error, _} -> {:close, binding}
            end

          {:error, :denied} ->
            log_request(binding, head, host, :denied)
            reply(client, 403, "Forbidden", [{"connection", "close"}])
            {:close, binding}
        end

      {:more, _} ->
        case :ssl.recv(client, 0, @idle_timeout) do
          {:ok, data} -> serve(client, upstream, host, port, binding, buffer <> data)
          {:error, _} -> {:close, binding}
        end

      {:error, _} ->
        reply(client, 400, "Bad Request", [{"connection", "close"}])
        {:close, binding}
    end
  end

  defp copy_body(client, upstream, framing, buffer) do
    case HTTP.take_body(framing, buffer) do
      {:done, bytes, rest} ->
        send_upstream(upstream, bytes)
        {:ok, rest}

      {:partial, bytes, framing} ->
        send_upstream(upstream, bytes)

        case :ssl.recv(client, 0, @idle_timeout) do
          {:ok, data} -> copy_body(client, upstream, framing, data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp send_upstream(_upstream, ""), do: :ok
  defp send_upstream(upstream, bytes), do: :ssl.send(upstream, bytes)

  # ---------------------------------------------------------------------------
  # Absolute-form: one plain-HTTP request, its response, then close

  defp forward_plain(socket, head, rest, host, port, target, binding) do
    with {:ok, headers, service} <- inject_or_deny(socket, head, host, port, target, binding),
         {:ok, address} <- resolve(socket, host, port),
         {:ok, upstream} <- connect_plain(socket, address, host, port) do
      log_request(binding, head, host, service)

      headers = [
        {"connection", "close"}
        | Enum.reject(headers, &(String.downcase(elem(&1, 0)) == "connection"))
      ]

      :ok = :gen_tcp.send(upstream, HTTP.encode_request(%{head | headers: headers}, target))

      case copy_body_plain(socket, upstream, HTTP.body_framing(head), rest) do
        :ok -> pump_plain(upstream, socket)
        {:error, _} -> :ok
      end

      :gen_tcp.close(upstream)
      {:close, binding}
    else
      {:error, _} -> {:close, binding}
    end
  end

  defp inject_or_deny(socket, head, host, port, target, binding) do
    case Injector.inject(head.headers, host, port, target, binding) do
      {:ok, _, _} = ok ->
        ok

      {:error, :denied} ->
        log_request(binding, head, host, :denied)
        reply(socket, 403, "Forbidden")
        {:error, :denied}
    end
  end

  defp connect_plain(socket, address, host, port) do
    case :gen_tcp.connect(address, port, [:binary, active: false], @connect_timeout) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.info("broker: upstream #{host}:#{port} unreachable: #{inspect(reason)}")
        reply(socket, 502, "Bad Gateway")
        {:error, reason}
    end
  end

  defp copy_body_plain(client, upstream, framing, buffer) do
    case HTTP.take_body(framing, buffer) do
      {:done, bytes, _rest} ->
        if bytes != "", do: :gen_tcp.send(upstream, bytes)
        :ok

      {:partial, bytes, framing} ->
        if bytes != "", do: :gen_tcp.send(upstream, bytes)

        case Socket.recv(client, 0, @idle_timeout) do
          {:ok, data} -> copy_body_plain(client, upstream, framing, data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp pump_plain(upstream, client) do
    case :gen_tcp.recv(upstream, 0, @idle_timeout) do
      {:ok, data} ->
        case Socket.send(client, data) do
          :ok -> pump_plain(upstream, client)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------

  defp upstream_ssl_options(host, state) do
    [
      mode: :binary,
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      alpn_advertised_protocols: ["http/1.1"],
      depth: 5
    ]
    |> Keyword.merge(state.upstream_ssl_options)
  end

  defp client_ssl_options(host) do
    Certs.for_host(host) ++
      [
        alpn_preferred_protocols: ["http/1.1"],
        reuse_sessions: false,
        handshake_timeout: @head_timeout
      ]
  end

  defp reply(socket, status, reason, headers \\ []) do
    lines = Enum.map(headers ++ [{"content-length", "0"}], fn {k, v} -> [k, ": ", v, "\r\n"] end)
    data = ["HTTP/1.1 ", Integer.to_string(status), " ", reason, "\r\n", lines, "\r\n"]

    case socket do
      %Socket{} -> Socket.send(socket, data)
      ssl -> :ssl.send(ssl, data)
    end
  end

  # The request log (ADR 0019 gate 4's half): who sent what where, and what
  # the proxy did about it. Never the headers, never a body.
  defp log_request(binding, head, host, outcome) do
    meta = %{
      conversation_id: binding.conversation_id,
      user_id: binding.user_id,
      method: head.method,
      host: host,
      path: path_only(head.target),
      outcome: outcome
    }

    :telemetry.execute([:fountain, :broker, :request], %{count: 1}, meta)

    Logger.info(
      "broker: conv #{binding.conversation_id} #{head.method} #{host}#{meta.path} " <>
        "#{describe(outcome)}"
    )
  end

  defp describe(nil), do: "passthrough"
  defp describe(:denied), do: "denied"
  defp describe(service), do: "injected #{service}"

  defp path_only("http://" <> _ = target), do: URI.parse(target).path || "/"
  defp path_only(target), do: target
end
