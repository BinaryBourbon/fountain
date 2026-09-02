defmodule Managoat.Broker do
  @moduledoc """
  An egress credential proxy for sandboxed agents.

  The sandbox holds a **placeholder** where a credential used to be, plus a
  proxy address with a session token in it. Outbound HTTP goes through this
  proxy, which looks the token up in the host's `Managoat.Broker.Store`,
  gets back the `Managoat.Broker.Session` of rules the host prepared, and
  attaches the real credential to each request that matches one. The
  sandbox's only permitted egress is the proxy, so a placeholder is
  worthless off the box. The pieces:

  | Module | Role |
  |---|---|
  | `Managoat.Broker` | this: the listener's child spec and supervisor |
  | `Managoat.Broker.Proxy` | one client connection: `CONNECT` tunnels with TLS terminated on both ends, absolute-form plain HTTP, the SSRF guard, the byte pump |
  | `Managoat.Broker.Injector` | the header rewrite for one request |
  | `Managoat.Broker.Rule`, `Managoat.Broker.Session` | what a token resolves to |
  | `Managoat.Broker.Store` | the behaviour the host implements: token in, session out |
  | `Managoat.Broker.Store.Memory` | the reference store, in memory |
  | `Managoat.Broker.CA`, `Managoat.Broker.Certs` | the root derived from the seed, and the cached per-host leaves |
  | `Managoat.Broker.HTTP` | request heads and body framing |

  ## Starting it

      children = [
        {Managoat.Broker,
         port: 14322,
         store: MyApp.BrokerSessions,
         ca_seed: MyApp.broker_ca_seed(),
         allow_private_upstreams: false}
      ]

  Every option but the last is required, and a missing one raises at start
  naming it. There is no configuration module reading an otp_app: the
  host computed these values at boot, and a library that is not started
  serves nothing.

  | Option | |
  |---|---|
  | `port` | the plaintext listener port (`0` for an ephemeral one; see `port/1`) |
  | `store` | a `Managoat.Broker.Store` module, or `{module, instance}` |
  | `ca_seed` | 32 bytes the root CA is derived from; the same seed on every replica |
  | `allow_private_upstreams` | default `false`. `true` lets the proxy dial private, loopback and link-local origins, for a test rig only |
  | `upstream_ssl_options` | default `[]`. Merged over the `:ssl` options the proxy dials origins with (a test origin's `cacerts`) |
  | `name` | default `Managoat.Broker`. The supervisor's name; `port/1`, `running?/1` and `ca_pem/1` take it |

  The root certificate the sandbox must trust is `ca_pem/1` once the
  listener is up, or `Managoat.Broker.CA.pem/1` from the seed at any time.
  """

  use Supervisor

  alias Managoat.Broker.{CA, Certs, Proxy}

  @required [:port, :store, :ca_seed]
  @idle_timeout 300_000

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Start the listener and its certificate cache under `name`."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    for key <- @required, not Keyword.has_key?(opts, key) do
      raise ArgumentError,
            "Managoat.Broker needs the #{inspect(key)} option; " <>
              "required: #{inspect(@required)}"
    end

    unless match?(<<_::binary-32>>, Keyword.fetch!(opts, :ca_seed)) do
      raise ArgumentError, "Managoat.Broker's :ca_seed must be 32 bytes"
    end

    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    certs = Certs.new(Keyword.fetch!(opts, :ca_seed))
    :persistent_term.put({__MODULE__, name, :certs}, certs)

    listener = %{
      id: :listener,
      start:
        {ThousandIsland, :start_link,
         [
           [
             port: Keyword.fetch!(opts, :port),
             handler_module: Proxy,
             handler_options: [
               store: Keyword.fetch!(opts, :store),
               certs: certs,
               allow_private_upstreams: Keyword.get(opts, :allow_private_upstreams, false),
               upstream_ssl_options: Keyword.get(opts, :upstream_ssl_options, [])
             ],
             read_timeout: @idle_timeout,
             supervisor_options: [name: listener_name(name)]
           ]
         ]},
      type: :supervisor
    }

    Supervisor.init([listener], strategy: :one_for_one)
  end

  @doc "True when the listener under `name` is up on this node."
  @spec running?(atom()) :: boolean()
  def running?(name \\ __MODULE__) do
    case Process.whereis(listener_name(name)) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc "The port the listener under `name` is bound to."
  @spec port(atom()) :: :inet.port_number()
  def port(name \\ __MODULE__) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener_name(name))
    port
  end

  @doc "The root certificate the listener under `name` signs with, as PEM."
  @spec ca_pem(atom()) :: String.t()
  def ca_pem(name \\ __MODULE__) do
    {__MODULE__, name, :certs} |> :persistent_term.get() |> Certs.ca_pem()
  end

  @doc "The root certificate a listener started with `seed` signs with, as PEM. Pure."
  @spec ca_pem_for_seed(binary()) :: String.t()
  def ca_pem_for_seed(seed), do: CA.pem(seed)

  defp listener_name(name), do: Module.concat(name, Listener)
end
