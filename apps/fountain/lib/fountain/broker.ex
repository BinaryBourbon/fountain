defmodule Fountain.Broker do
  @moduledoc """
  The egress credential broker (ADR 0019, gate 1a).

  A brokered conversation's sandbox holds a **placeholder** where a
  credential used to be, plus a proxy address. The real value lives in an
  [Agent Vault](https://github.com/Infisical/agent-vault) instance, loaded
  from the same DEK-encrypted rows it always lived in, and is attached to the
  outbound request at the proxy. The sandbox's only permitted egress is the
  proxy, so a placeholder is worthless off the box.

  This module is the whole seam: the Agent Vault HTTP client, the catalog of
  secrets the broker knows how to carry, and the placeholder rule. It is one
  module with the vendor client inside it on purpose (ADR 0019 §8) — the
  abstraction is worth building on the day there is a second broker.

  ## What is brokered

  * A secret with an enabled **binding** (`Fountain.SecretBindings`, gate 1b):
    the tenant said which host it goes to and how. One service per binding.
  * `GITHUB_TOKEN` and `GH_TOKEN` with no binding of their own, bound by the
    built-in catalog to `api.github.com` (bearer) and `github.com` (git over
    HTTPS, basic `x-access-token`) — gate 1a's default, kept so a tenant who
    never opens the bindings page keeps working.
  * Every other secret reaches the sandbox exactly as before.

  ## The network policy (gate 2)

  The sandbox's own policy is always the floor, `allow: [broker]`. What the
  environment's `networking_type` says is enforced **at the broker**:
  `unrestricted` sets the vault's unmatched-host policy to `passthrough`, so
  the agent may reach any host but only ever with the credentials it was
  granted; `limited` sets it to `deny` and turns `allowed_hosts` into
  passthrough services, so an unlisted host is refused with a 403 that names
  the host. Tenant intent is preserved and gains per-host visibility in the
  broker's request log.
  * Only tenants listed in `BROKER_TENANTS`: the operator ratchet of §9.
  * Only `unrestricted` environments. Translating `limited`'s `allowed_hosts`
    into broker rules is gate 2; a brokered `limited` environment is refused
    by name at preflight rather than half-enforced.
  * Not inference credentials (gate 3) and not the joined request log
    (gate 4).

  ## Custody

  One broker vault per **conversation**, named from the conversation id,
  deleted when the conversation ends. ADR 0019 §11 said one per tenant; that
  shape breaks the moment one tenant runs two conversations with different
  `GITHUB_TOKEN`s at once (one vault, one key, last write wins), and a
  per-conversation vault is also what gate 4 needs to attribute the request
  log. The tenant-level guarantee §11 cared about — a session cannot read
  another vault — holds either way: the binding is on the token.

  The session token is minted with the `proxy` vault role (it may broker,
  never read), lives `BROKER_SESSION_TTL_SECONDS`, and travels to the sandbox
  inside `HTTPS_PROXY`, which is why that variable is process-only in
  `Fountain.Conversations.Identity` and never reaches the shared `.env`.

  ## Off means off

  `configured?/0` is false when `BROKER_URL` is blank, and then no function
  here makes an HTTP call and provisioning is byte-for-byte what it was.
  """

  require Logger

  @ca_path "/usr/local/share/ca-certificates/agent-vault.crt"

  @typedoc "A minted proxy session for one conversation."
  @type session :: %{
          vault: String.t(),
          token: String.t(),
          expires_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Configuration

  @doc "True when `BROKER_URL` is set. Nothing here talks to the network otherwise."
  @spec configured?() :: boolean()
  def configured?, do: is_binary(Application.get_env(:fountain, :broker_url))

  @doc "True when the broker is configured and this tenant is on the ratchet."
  @spec enabled_for?(String.t() | nil) :: boolean()
  def enabled_for?(user_id) when is_binary(user_id) do
    configured?() and user_id in Application.get_env(:fountain, :broker_tenants, [])
  end

  def enabled_for?(_), do: false

  @doc "The address the sandbox dials, without a credential."
  @spec proxy_url() :: String.t()
  def proxy_url, do: Application.fetch_env!(:fountain, :broker_proxy_url)

  @doc "The one host a brokered sandbox may reach."
  @spec proxy_host() :: String.t()
  def proxy_host, do: URI.parse(proxy_url()).host

  @doc "Whether a provider without `:network_policy` may host a brokered conversation."
  @spec allow_unenforced?() :: boolean()
  def allow_unenforced?, do: Application.get_env(:fountain, :broker_allow_unenforced, false)

  @doc "Where the broker CA lands in the sandbox. Node reads it through `NODE_EXTRA_CA_CERTS`."
  @spec ca_path() :: String.t()
  def ca_path, do: @ca_path

  @doc "Where the PEM is written first, as the sandbox user, before sudo moves it into the trust store."
  @spec ca_staging_path() :: String.t()
  def ca_staging_path, do: "/tmp/agent-vault-ca.crt"

  # ---------------------------------------------------------------------------
  # The catalog and the placeholder rule

  # Key name → the services the broker attaches it to. A binding needs a host
  # and an auth shape; today a secret is `{key, value}` and nothing else, so
  # the catalog is what supplies both, by key name. The tail of secrets that
  # need an explicit host is gate 1b (#1090).
  @catalog %{
    "GITHUB_TOKEN" => :github,
    "GH_TOKEN" => :github
  }

  @doc "The secret keys gate 1a knows how to broker."
  @spec catalog_keys() :: [String.t()]
  def catalog_keys, do: Map.keys(@catalog)

  @doc """
  The placeholder a brokered key carries in the sandbox.

  Lowercase, wrapped in double underscores, so it is visibly not a token and
  so a client that validates its own token's shape (some do) still sends it.
  The broker replaces the whole auth header, so the value never has to match
  anything on the other side.
  """
  @spec placeholder(String.t()) :: String.t()
  def placeholder(key), do: "__" <> String.downcase(key) <> "__"

  @typedoc "Enabled bindings grouped by secret key, as `Fountain.SecretBindings.enabled_by_key/1` returns them."
  @type bindings :: %{String.t() => [Fountain.SecretBindings.Binding.t()]}

  @doc """
  Split a merged secrets map into what the sandbox gets and what the broker
  gets. Runs on the merged map, so the vault-wins rule has already applied
  (ADR 0019 §9: brokering happens after the merge).

  A key is brokered when it has an enabled binding, or when it is a catalog
  key (`GITHUB_TOKEN`, `GH_TOKEN`) with none. Returns `{sandbox_secrets,
  brokered}`: a placeholder in the first map, the value in the second. Keys
  with an empty value are left alone: there is nothing to broker.
  """
  @spec split(%{String.t() => String.t()}, bindings()) ::
          {%{String.t() => String.t()}, %{String.t() => String.t()}}
  def split(secrets, bindings \\ %{}) when is_map(secrets) and is_map(bindings) do
    Enum.reduce(secrets, {%{}, %{}}, fn {k, v}, {sandbox, brokered} ->
      if brokered?(k, bindings) and is_binary(v) and v != "" do
        {Map.put(sandbox, k, placeholder(k)), Map.put(brokered, k, v)}
      else
        {Map.put(sandbox, k, v), brokered}
      end
    end)
  end

  defp brokered?(key, bindings), do: Map.has_key?(bindings, key) or Map.has_key?(@catalog, key)

  # The services a set of brokered keys turns into: one per binding, in the
  # broker's shape (one host per service, only the fields of the auth type),
  # plus the catalog pair for a GitHub key that has no bindings of its own.
  defp services_for(brokered, bindings) do
    bound =
      brokered
      |> Map.keys()
      |> Enum.flat_map(fn key ->
        bindings |> Map.get(key, []) |> Enum.map(&binding_service(key, &1))
      end)

    catalog =
      if Enum.any?(brokered, fn {k, _} ->
           Map.get(@catalog, k) == :github and not Map.has_key?(bindings, k)
         end) do
        key = github_key(brokered, bindings)

        [
          %{name: "github-api", host: "api.github.com", auth: %{type: "bearer", token: key}},
          %{
            name: "github-git",
            host: "github.com",
            auth: %{type: "basic", username: basic_user_key(key), password: key}
          }
        ]
      else
        []
      end

    bound ++ catalog
  end

  # Both names may be present after the merge; the git URL is written with
  # whichever one `repositories[].secret_key` names, and the broker needs a
  # single credential per service. Prefer the canonical name.
  defp github_key(brokered, bindings) do
    cond do
      Map.has_key?(brokered, "GITHUB_TOKEN") and not Map.has_key?(bindings, "GITHUB_TOKEN") ->
        "GITHUB_TOKEN"

      true ->
        "GH_TOKEN"
    end
  end

  defp binding_service(key, binding) do
    auth =
      case binding.auth_type do
        "bearer" -> %{type: "bearer", token: key}
        "basic" -> %{type: "basic", username: basic_user_key(key), password: key}
        "api_key" -> %{type: "api-key", key: key, header: binding.header, prefix: binding.prefix}
        "custom" -> %{type: "custom", headers: binding.headers}
      end
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    %{name: service_name(key, binding.host), host: binding.host, auth: auth}
  end

  # A slug the broker accepts (`[a-z0-9-]{3,64}`, no `--`, no edge hyphen)
  # that is stable for a key+host pair, so a re-prepare upserts rather than
  # accumulates.
  @doc false
  def service_name(key, host) do
    base =
      (key <> "-" <> host)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    base = if String.length(base) < 3, do: base <> "-svc", else: base
    String.slice(base, 0, 64) |> String.trim("-")
  end

  # The basic-auth username lives beside the password as a credential, because
  # that is the only place a service may read one from. Its name derives from
  # the key so two basic bindings of different keys never collide.
  defp basic_user_key(key), do: key <> "_BASIC_USER"

  # Credentials the services reference beyond the tenant's own values: one
  # basic-auth username per basic binding (the tenant's literal), and GitHub's
  # constant `x-access-token` for the catalog default.
  defp credentials_for(brokered, bindings) do
    from_bindings =
      brokered
      |> Map.keys()
      |> Enum.flat_map(fn key ->
        bindings
        |> Map.get(key, [])
        |> Enum.filter(&(&1.auth_type == "basic"))
        |> Enum.map(fn b -> {basic_user_key(key), b.username} end)
      end)
      |> Map.new()

    from_catalog =
      brokered
      |> Map.keys()
      |> Enum.filter(&(Map.get(@catalog, &1) == :github and not Map.has_key?(bindings, &1)))
      |> Map.new(fn key -> {basic_user_key(key), "x-access-token"} end)

    brokered |> Map.merge(from_bindings) |> Map.merge(from_catalog)
  end

  # ---------------------------------------------------------------------------
  # The sandbox side

  @doc "The broker vault name for a conversation. `[a-z0-9-]`, 3 to 64 characters."
  @spec vault_name(String.t()) :: String.t()
  def vault_name(conversation_id) when is_binary(conversation_id) do
    "c-" <> (conversation_id |> String.downcase() |> String.replace(~r/[^a-z0-9]/, ""))
  end

  @doc """
  The environment pairs a brokered sandbox gets. `HTTPS_PROXY` carries the
  session token (as `http://<token>:<vault>@host:port`), so it is process-only
  (`Identity.@process_only`); the lower case twins are for apt and the tools
  that only read those.
  """
  @spec sandbox_env(session()) :: [{String.t(), String.t()}]
  def sandbox_env(%{token: token, vault: vault}) do
    url = proxy_url_with(token, vault)

    [
      {"HTTPS_PROXY", url},
      {"HTTP_PROXY", url},
      {"https_proxy", url},
      {"http_proxy", url},
      {"NO_PROXY", "localhost,127.0.0.1"},
      {"NODE_EXTRA_CA_CERTS", @ca_path}
    ]
  end

  @doc "Every variable `sandbox_env/1` sets, for a refresh to replace."
  @spec env_keys() :: [String.t()]
  def env_keys, do: ~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY NODE_EXTRA_CA_CERTS)

  @doc "The variables that carry the session token, which `Identity` keeps off the shared `.env`."
  @spec process_only_keys() :: [String.t()]
  def process_only_keys, do: ~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy)

  # Both userinfo fields, on purpose (gate 0): with the token alone curl is
  # happy and git stops to ask for a *proxy* password. The broker reads
  # `Basic base64(token:vault)` and requires the vault to match the token's.
  defp proxy_url_with(token, vault) do
    uri = URI.parse(proxy_url())
    URI.to_string(%{uri | userinfo: token <> ":" <> vault})
  end

  @doc "True when the session ends within `within_seconds` (default ten minutes), or has no known end."
  @spec expiring?(session(), non_neg_integer()) :: boolean()
  def expiring?(session, within_seconds \\ 600)

  def expiring?(%{expires_at: %DateTime{} = at}, within_seconds) do
    DateTime.diff(at, DateTime.utc_now(), :second) < within_seconds
  end

  def expiring?(_, _), do: true

  # ---------------------------------------------------------------------------
  # Calls to the broker. Each returns `:ok`/`{:ok, _}` or `{:error, reason}`;
  # retries belong to the caller, per the repo's client convention.

  @doc "Is the broker up? The preflight; a `false` here fails provisioning before a sandbox exists."
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    case Req.get(req(auth: false), url: "/health") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:broker, :unreachable, {status, body}}}
      {:error, reason} -> {:error, {:broker, :unreachable, reason}}
    end
  end

  @doc "The root CA the proxy signs with. The sandbox trusts it or nothing works."
  @spec ca_pem() :: {:ok, binary()} | {:error, term()}
  def ca_pem do
    case Req.get(req(auth: false), url: "/v1/mitm/ca.pem") do
      {:ok, %{status: 200, body: pem}} when is_binary(pem) -> {:ok, pem}
      other -> {:error, {:broker, :ca, normalize(other)}}
    end
  end

  @doc """
  Make the broker ready for one conversation and mint its session.

  Idempotent: the vault is created if missing, the credentials and services
  are upserted, and a fresh session is minted every call. Runs on every
  provision and reattach, so an edited secret reaches the broker on the next
  wake, the same way the `.env` file is refreshed.
  """
  @typedoc "What the environment's `networking_type` asks for: reach anything, or only these hosts."
  @type network :: :unrestricted | {:limited, [String.t()]}

  @spec prepare(String.t(), %{String.t() => String.t()}, bindings(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings \\ %{}, opts \\ [])
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    vault = vault_name(conversation_id)
    network = Keyword.get(opts, :network, :unrestricted)
    credentialed = services_for(brokered, bindings)

    with :ok <- ensure_vault(vault),
         :ok <- set_policy(vault, policy_for(network)),
         :ok <- put_credentials(vault, credentials_for(brokered, bindings)),
         :ok <- put_services(vault, credentialed ++ allow_services(network, credentialed)) do
      mint_session(vault, conversation_id)
    end
  end

  defp policy_for(:unrestricted), do: "passthrough"
  defp policy_for({:limited, _hosts}), do: "deny"

  # `limited`: one passthrough service per allowed host, so the deny policy
  # has something to match. A host that already carries a credential service
  # is skipped — the credentialed entry is the one that must win there.
  defp allow_services(:unrestricted, _credentialed), do: []

  defp allow_services({:limited, hosts}, credentialed) do
    taken = MapSet.new(credentialed, & &1.host)

    hosts
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or MapSet.member?(taken, &1)))
    |> Enum.uniq()
    |> Enum.map(fn host ->
      %{name: service_name("ALLOW", host), host: host, auth: %{type: "passthrough"}}
    end)
  end

  @doc "The network shape an environment asks for, as `prepare/4` takes it."
  @spec network_for(map() | nil) :: network()
  def network_for(%{networking_type: "limited", networking_config: config}) do
    {:limited, (config && (config["allowed_hosts"] || config[:allowed_hosts])) || []}
  end

  def network_for(_), do: :unrestricted

  @doc "Delete the conversation's vault: its credentials, services and sessions go with it."
  @spec release(String.t()) :: :ok | {:error, term()}
  def release(conversation_id) when is_binary(conversation_id) do
    vault = vault_name(conversation_id)

    case Req.delete(req(), url: "/v1/vaults/#{vault}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      other -> {:error, {:broker, :release, normalize(other)}}
    end
  end

  defp ensure_vault(vault) do
    case Req.post(req(), url: "/v1/vaults", json: %{name: vault}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 409}} -> :ok
      other -> {:error, {:broker, :vault, normalize(other)}}
    end
  end

  # Explicit even for the default: the broker defaults to passthrough and has
  # no flag for it, and gate 2 flips this to deny for `limited`. Written on
  # every prepare so a vault that survived from a different setting is reset.
  defp set_policy(vault, policy) do
    case Req.patch(req(),
           url: "/v1/vaults/#{vault}/settings",
           json: %{unmatched_host_policy: policy}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, {:broker, :policy, normalize(other)}}
    end
  end

  defp put_credentials(_vault, creds) when map_size(creds) == 0, do: :ok

  defp put_credentials(vault, creds) do
    case Req.post(req(), url: "/v1/credentials", json: %{vault: vault, credentials: creds}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, {:broker, :credentials, normalize(other)}}
    end
  end

  # PUT replaces the list, so a key that left the tenant's secrets leaves the
  # broker too instead of lingering from an earlier prepare.
  defp put_services(vault, services) do
    case Req.put(req(), url: "/v1/vaults/#{vault}/services", json: %{services: services}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, {:broker, :services, normalize(other)}}
    end
  end

  defp mint_session(vault, conversation_id) do
    body = %{
      vault: vault,
      vault_role: "proxy",
      ttl_seconds: Application.get_env(:fountain, :broker_session_ttl_seconds, 21_600),
      label: "conversation " <> conversation_id
    }

    case Req.post(req(), url: "/v1/sessions", json: body) do
      {:ok, %{status: status, body: %{"token" => token} = resp}}
      when status in 200..299 and is_binary(token) ->
        {:ok, %{vault: vault, token: token, expires_at: parse_time(resp["expires_at"])}}

      other ->
        {:error, {:broker, :session, normalize(other)}}
    end
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp normalize({:ok, %{status: status, body: body}}), do: {:api_error, status, body}
  defp normalize({:error, reason}), do: reason

  # The token is never logged: Req's default error inspection would print the
  # request, so failures above carry status and body only.
  defp req(opts \\ []) do
    base =
      [
        base_url: Application.fetch_env!(:fountain, :broker_url),
        receive_timeout: Application.get_env(:fountain, :broker_timeout_ms, 10_000),
        retry: false
      ] ++ Application.get_env(:fountain, :broker_req_options, [])

    base =
      if Keyword.get(opts, :auth, true),
        do: Keyword.put(base, :auth, {:bearer, Application.fetch_env!(:fountain, :broker_token)}),
        else: base

    Req.new(base)
  end
end
