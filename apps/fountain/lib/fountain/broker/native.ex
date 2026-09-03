defmodule Fountain.Broker.Native do
  @moduledoc """
  The native backend of `Fountain.Broker`: the `Managoat.Broker` proxy run
  inside this application (#1340, ADR 0019 §8 as amended). Selected by
  `BROKER_LISTEN_PORT`.

  `prepare/4` maps the conversation's brokered keys and bindings to
  `Managoat.Broker.Rule`s and stores them, encrypted under the tenant's DEK,
  as a `Fountain.Broker.Native.Sessions` row keyed by the hash of a fresh
  token. The proxy resolves the token back to the rules on every new sandbox
  connection through the `Managoat.Broker.Store` behaviour that module
  implements, on whichever replica the ingress chose. `release/1` deletes
  the conversation's rows; `Fountain.Workers.BrokerVaultReaper` sweeps the
  expired ones.

  The listener is started by `Fountain.Application` from `listener_spec/0`.
  Its root CA is derived from `ca_seed/0`, thirty-two bytes HKDF-derived from
  the master key with a fixed info string, so every replica presents the same
  root and nothing is stored; `ca_pem/0` is that root.

  The request log is the `[:managoat, :broker, :request]` telemetry event
  the proxy emits. `attach_telemetry/0` writes one log line per request
  naming the conversation, method, host, path and outcome, never a header,
  and buffers a `broker_requests` row through
  `Fountain.Broker.Native.RequestLog` for `GET /api/conversations/:id/egress`
  to read back (gate 4, #1486). Response status and latency stay unset until
  the proxy frames responses; everything else the Agent Vault backend
  returned is there.

  `emit_telemetry/0` is the poller tick behind the `fountain_broker_*`
  gauges (#1170): the listener, the live session count and the CA's
  remaining life. The alerts that read them are in home-cloud.
  """

  alias Fountain.Broker
  alias Fountain.Broker.Native.RequestLog
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Conversations.Conversation
  alias Fountain.Repo
  alias Managoat.Broker.Rule

  import Ecto.Query, only: [from: 2]

  require Logger

  @ca_info "managoat-broker-ca"
  @telemetry_handler "fountain-broker-native-request"

  # ---------------------------------------------------------------------------
  # The listener

  @doc """
  The child spec `Fountain.Application` starts when this backend is
  selected: the `Managoat.Broker` listener on `BROKER_LISTEN_PORT`, with
  `Fountain.Broker.Native.Sessions` as its store and `ca_seed/0` as its CA.
  """
  @spec listener_spec() :: {module(), keyword()}
  def listener_spec do
    {Managoat.Broker,
     port: Application.fetch_env!(:fountain, :broker_listen_port),
     store: Sessions,
     ca_seed: ca_seed(),
     allow_private_upstreams:
       Application.get_env(:fountain, :broker_allow_private_upstreams, false)}
  end

  @doc """
  The seed the broker CA is derived from: HKDF-SHA256 over the master key
  with the info string `"#{@ca_info}"`, so the CA key is never the storage
  key, every replica derives the same root, and rotating the master key
  rotates the CA.
  """
  @spec ca_seed() :: <<_::256>>
  def ca_seed do
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, master_key())
    :crypto.mac(:hmac, :sha256, prk, @ca_info <> <<1>>)
  end

  defp master_key do
    case Application.fetch_env!(:fountain, :master_secrets_key) do
      <<_::binary-32>> = key -> key
      other -> raise "MASTER_SECRETS_KEY must be 32 bytes, got #{byte_size(other)}"
    end
  end

  @doc """
  Record every proxied request: one log line, and one buffered
  `broker_requests` row. Idempotent.
  """
  @spec attach_telemetry() :: :ok
  def attach_telemetry do
    case :telemetry.attach(
           @telemetry_handler,
           [:managoat, :broker, :request],
           &__MODULE__.handle_request/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # `:telemetry` detaches a handler that raises, for the life of the node
  # (#1427), so this one cannot be allowed to. The whole body is guarded and
  # the row goes through a cast, never a synchronous insert on the proxy's
  # own connection process.
  @doc false
  def handle_request(_event, _measurements, meta, _config) do
    session = Map.get(meta, :meta) || %{}
    conv = session["conversation_id"]

    Logger.info(
      "broker: conv #{conv || "?"} #{meta.method} #{meta.host}#{meta.path} " <>
        describe(meta.outcome, meta.rule)
    )

    if is_binary(conv) and is_binary(session["user_id"]) do
      RequestLog.record(row(meta, session, conv))
    end

    :ok
  rescue
    error ->
      Logger.warning("broker: request log handler skipped a row: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("broker: request log handler skipped a row: #{inspect({kind, reason})}")
      :ok
  end

  # `credential_keys` names the environment variables whose values the proxy
  # attached, never the values: the same thing an audit row records for a
  # secret. The rule-to-keys map rides on the session's `meta`, put there by
  # `prepare/4`, because the proxy knows only the rule that matched.
  defp row(meta, session, conv) do
    rule = meta.rule && to_string(meta.rule)

    %{
      conversation_id: conv,
      user_id: session["user_id"],
      method: clip(meta.method, 16),
      host: clip(meta.host, 255),
      path: clip(meta.path, 2048),
      outcome: to_string(meta.outcome),
      service: rule && clip(rule, 255),
      credential_keys: (rule && get_in(session, ["credential_keys", rule])) || [],
      inserted_at: DateTime.utc_now()
    }
  end

  # Postgres counts `varchar(n)` in characters, so does `String.slice/3`, and
  # slicing on graphemes cannot produce the invalid UTF-8 that would make the
  # whole batch fail to insert.
  defp clip(nil, _max), do: ""
  defp clip(value, max), do: value |> to_string() |> String.slice(0, max)

  defp describe(:injected, rule), do: "injected #{rule}"
  defp describe(:passthrough, _), do: "passthrough"
  defp describe(:denied, _), do: "denied"

  # ---------------------------------------------------------------------------
  # The backend

  @doc "Is the listener up on this node?"
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    if Managoat.Broker.running?(),
      do: :ok,
      else: {:error, {:broker, :unreachable, :listener_down}}
  end

  @doc "The derived root, as PEM."
  @spec ca_pem() :: {:ok, binary()}
  def ca_pem, do: {:ok, Managoat.Broker.ca_pem_for_seed(ca_seed())}

  @doc """
  Mint the conversation's session: the rules the proxy may apply (one or
  two per binding, the catalog pair for an unbound GitHub key, a passthrough
  per allowed host under `limited`), stored under the tenant's key with a
  fresh token. `opts[:user_id]` names the tenant; without it the
  conversation row does.
  """
  @spec prepare(String.t(), %{String.t() => String.t()}, Broker.bindings(), keyword()) ::
          {:ok, Broker.session()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings, opts)
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    network = Keyword.get(opts, :network, :unrestricted)

    with {:ok, user_id} <- user_id(conversation_id, opts) do
      Sessions.create(%{
        conversation_id: conversation_id,
        user_id: user_id,
        rules: rules_for(brokered, bindings, network),
        unmatched_host_policy: policy_for(network),
        meta: %{
          "conversation_id" => conversation_id,
          "user_id" => user_id,
          "credential_keys" => credential_keys(brokered, bindings)
        },
        ttl_seconds: Application.get_env(:fountain, :broker_session_ttl_seconds, 21_600)
      })
    end
  end

  defp user_id(conversation_id, opts) do
    case Keyword.get(opts, :user_id) do
      id when is_binary(id) ->
        {:ok, id}

      nil ->
        case Repo.one(from(c in Conversation, where: c.id == ^conversation_id, select: c.user_id)) do
          nil -> {:error, {:broker, :session, :unknown_conversation}}
          id -> {:ok, id}
        end
    end
  end

  defp policy_for(:unrestricted), do: :passthrough
  defp policy_for({:limited, _hosts}), do: :deny

  @doc """
  The rules a set of brokered keys turns into, in the order the proxy
  consults them: one per binding (plus a header-value substitution twin for
  every header-setting shape, so the placeholder is replaced wherever a
  client puts it), the catalog pair for a GitHub key with no bindings of
  its own, then under `limited` a passthrough per allowed host that no
  credentialed rule already covers.
  """
  @spec rules_for(%{String.t() => String.t()}, Broker.bindings(), Broker.network()) :: [Rule.t()]
  def rules_for(brokered, bindings, network) do
    bound =
      brokered
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, value} ->
        bindings |> Map.get(key, []) |> Enum.flat_map(&binding_rules(key, value, &1, brokered))
      end)

    credentialed = bound ++ catalog_rules(brokered, bindings)
    credentialed ++ allow_rules(network, credentialed)
  end

  defp binding_rules(key, value, binding, brokered) do
    name = Broker.service_name(key, binding.host)
    base = %Rule{name: name, pattern: binding.host, scheme: :passthrough}
    twin = %{base | scheme: :substitute, placeholder: Broker.placeholder(key), credential: value}

    case binding.auth_type do
      "substitute" ->
        [twin]

      "bearer" ->
        [%{base | scheme: :bearer, credential: value}, twin]

      "basic" ->
        [%{base | scheme: :basic, credential: {binding.username || "", value}}, twin]

      "api_key" ->
        [
          %{
            base
            | scheme: :api_key,
              header: binding.header,
              prefix: binding.prefix || "",
              credential: value
          },
          twin
        ]

      "custom" ->
        [%{base | scheme: :custom, template: binding.headers || %{}, credential: brokered}, twin]
    end
  end

  # Gate 1a's default: an unbound GitHub key goes to api.github.com as a
  # bearer and to github.com as git's basic `x-access-token`.
  defp catalog_rules(brokered, bindings) do
    case Broker.catalog_github_key(brokered, bindings) do
      nil ->
        []

      key ->
        value = Map.fetch!(brokered, key)
        placeholder = Broker.placeholder(key)

        [
          %Rule{
            name: "github-api",
            pattern: "api.github.com",
            scheme: :bearer,
            credential: value
          },
          %Rule{
            name: "github-api",
            pattern: "api.github.com",
            scheme: :substitute,
            placeholder: placeholder,
            credential: value
          },
          %Rule{
            name: "github-git",
            pattern: "github.com",
            scheme: :basic,
            credential: {Broker.github_basic_user(), value}
          }
        ]
    end
  end

  # `limited`: one passthrough rule per allowed host, so the deny policy has
  # something to match. A host that already carries a credentialed rule is
  # skipped — that rule is the one that must win there.
  defp allow_rules(:unrestricted, _credentialed), do: []

  defp allow_rules({:limited, hosts}, credentialed) do
    taken = MapSet.new(credentialed, & &1.pattern)

    hosts
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or MapSet.member?(taken, &1)))
    |> Enum.uniq()
    |> Enum.map(fn host ->
      %Rule{name: Broker.service_name("ALLOW", host), pattern: host, scheme: :passthrough}
    end)
  end

  @doc "Delete the conversation's sessions. Its tokens stop working at once."
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id),
    do: Sessions.release(conversation_id)

  @doc """
  The conversation's egress rows, newest first (gate 4, #1486). The same
  shape the Agent Vault backend answered with, except that `status`,
  `latency_ms` and `error` are `nil` until the proxy frames responses.
  """
  @spec request_log(String.t(), keyword()) ::
          {:ok, %{events: [Broker.egress_event()], next: integer() | nil}}
  def request_log(conversation_id, opts), do: RequestLog.page(conversation_id, opts)

  # ---------------------------------------------------------------------------
  # Gauges (#1170)

  @doc """
  The poller tick behind the `fountain_broker_*` series: is the listener up
  on this node, how many sessions are live, and how long the derived CA has
  left. Emits nothing on a deployment that does not run this backend, so the
  series exist exactly where the alerts mean something.
  """
  @spec emit_telemetry() :: :ok
  def emit_telemetry do
    if Broker.backend() == :native do
      Fountain.TelemetryTick.run("broker gauges", fn ->
        up = if Managoat.Broker.running?(), do: 1, else: 0
        :telemetry.execute([:fountain, :broker, :listener], %{up: up}, %{})

        :telemetry.execute(
          [:fountain, :broker, :sessions],
          %{count: Repo.aggregate(Fountain.Broker.Native.Session, :count, :id)},
          %{}
        )

        :telemetry.execute(
          [:fountain, :broker, :ca],
          %{expires_in_seconds: ca_expires_in_seconds()},
          %{}
        )
      end)
    end

    :ok
  end

  # The root the library derives has a fixed twenty-year window today, so
  # this reads as a constant. It is exported anyway: the number is the one
  # thing that turns "the CA is fine" from an assumption into a series, and
  # a library that ever shortens the window becomes visible here rather than
  # on the day every sandbox stops trusting the proxy.
  defp ca_expires_in_seconds do
    {:ok, pem} = ca_pem()

    not_after =
      pem
      |> X509.Certificate.from_pem!()
      |> X509.Certificate.validity()
      |> elem(2)
      |> X509.DateTime.to_datetime()

    DateTime.diff(not_after, DateTime.utc_now())
  end

  # Which environment variables each rule's credential came from, by rule
  # name, mirroring how `rules_for/3` names them. Stored on the session so
  # the request log can say which credential was attached without the proxy
  # ever knowing an environment variable's name.
  @spec credential_keys(%{String.t() => String.t()}, Broker.bindings()) :: %{
          String.t() => [String.t()]
        }
  def credential_keys(brokered, bindings) do
    bound =
      brokered
      |> Enum.flat_map(fn {key, _value} ->
        bindings |> Map.get(key, []) |> Enum.map(&{Broker.service_name(key, &1.host), key})
      end)

    catalog =
      case Broker.catalog_github_key(brokered, bindings) do
        nil -> []
        key -> [{"github-api", key}, {"github-git", key}]
      end

    (bound ++ catalog)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, keys} -> {name, keys |> Enum.uniq() |> Enum.sort()} end)
  end
end
