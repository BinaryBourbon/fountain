defmodule Fountain.Broker do
  @moduledoc """
  The egress credential broker (ADR 0019).

  A brokered conversation's sandbox holds a **placeholder** where a
  credential used to be, plus a proxy address. The real value stays in the
  DEK-encrypted rows it always lived in, is copied (still under the tenant
  DEK) into a `Fountain.Broker.Session` for the life of the conversation,
  and is attached to the outbound request by `Fountain.Broker.Proxy`, which
  Fountain runs itself. The sandbox's only permitted egress is the proxy,
  so a placeholder is worthless off the box.

  This module is the seam the rest of the app talks to: the catalog of
  secrets the broker knows how to carry, the placeholder rule, and the
  session lifecycle. Gate 1a shipped it as a client for Infisical's Agent
  Vault (#1136); §8 of the ADR was amended when the broker moved in-house,
  and the module's callers did not change.

  ## What is brokered

  * A secret with an enabled **binding** (`Fountain.SecretBindings`, gate 1b):
    the tenant said which host it goes to and how. One service per binding.
  * `GITHUB_TOKEN` and `GH_TOKEN` with no binding of their own, bound by the
    built-in catalog to `api.github.com` (bearer) and `github.com` (git over
    HTTPS, basic `x-access-token`) — gate 1a's default, kept so a tenant who
    never opens the bindings page keeps working.
  * Every other secret reaches the sandbox exactly as before.
  * Only tenants listed in `BROKER_TENANTS`: the operator ratchet of §9.
  * Only `unrestricted` environments. Translating `limited`'s `allowed_hosts`
    into broker rules is gate 2; a brokered `limited` environment is refused
    by name at preflight rather than half-enforced.
  * Not inference credentials (gate 3) and not the joined request log
    (gate 4).

  ## Custody

  One session per **conversation**, named `c-<conversation id>` for the
  proxy URL, deleted when the conversation ends (ADR 0019 §11). The binding
  is on the token: a token resolves to its own conversation's credentials
  and to nothing else, whichever vault name the URL carries.

  The session token lives `BROKER_SESSION_TTL_SECONDS` and travels to the
  sandbox inside `HTTPS_PROXY`, which is why that variable is process-only
  in `Fountain.Conversations.Identity` and never reaches the shared `.env`.

  ## Off means off

  `configured?/0` is false when `BROKER_LISTEN_PORT` and `BROKER_PROXY_URL`
  are blank, and then no listener runs and provisioning is byte-for-byte
  what it was.
  """

  alias Fountain.Broker.{CA, Proxy, Sessions}

  @ca_path "/usr/local/share/ca-certificates/fountain-broker.crt"

  @typedoc "A minted proxy session for one conversation."
  @type session :: %{
          vault: String.t(),
          token: String.t(),
          expires_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Configuration

  @doc "True when `BROKER_LISTEN_PORT` and `BROKER_PROXY_URL` are set. Nothing listens otherwise."
  @spec configured?() :: boolean()
  def configured? do
    is_integer(Application.get_env(:fountain, :broker_listen_port)) and
      is_binary(Application.get_env(:fountain, :broker_proxy_url))
  end

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
  def ca_staging_path, do: "/tmp/fountain-broker-ca.crt"

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

  @doc "The vault name in a conversation's proxy URL: the conversation id in `[a-z0-9-]`."
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
  # The session lifecycle

  @doc "Is the proxy listening? The preflight; a failure here stops provisioning before a sandbox exists."
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    if Proxy.running?(), do: :ok, else: {:error, {:broker, :unreachable, :listener_down}}
  end

  @doc "The root CA the proxy signs with. The sandbox trusts it or nothing works."
  @spec ca_pem() :: {:ok, binary()} | {:error, term()}
  def ca_pem, do: {:ok, CA.pem()}

  @doc """
  Mint the conversation's session: the credentials the proxy may attach,
  the services that say where (one per binding, plus the catalog pair for
  an unbound GitHub key), and a fresh token.

  Runs on every provision and reattach, so an edited secret or binding
  reaches the proxy on the next wake, the same way the `.env` file is
  refreshed. The previous session, if any, stays valid until it expires: a
  turn already running on it is not cut off.
  """
  @spec prepare(String.t(), String.t(), %{String.t() => String.t()}, bindings()) ::
          {:ok, session()} | {:error, term()}
  def prepare(conversation_id, user_id, brokered, bindings \\ %{})
      when is_binary(conversation_id) and is_binary(user_id) and is_map(brokered) and
             is_map(bindings) do
    Sessions.create(%{
      conversation_id: conversation_id,
      user_id: user_id,
      vault: vault_name(conversation_id),
      credentials: credentials_for(brokered, bindings),
      services: services_for(brokered, bindings),
      unmatched_host_policy: "passthrough",
      ttl_seconds: Application.get_env(:fountain, :broker_session_ttl_seconds, 21_600)
    })
  end

  @doc "Delete the conversation's sessions. Its tokens stop working at once."
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id),
    do: Sessions.release(conversation_id)
end
