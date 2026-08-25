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

  ## What gate 1a brokers, and what it does not

  * Only `GITHUB_TOKEN` and `GH_TOKEN`, bound by the catalog to
    `api.github.com` (bearer) and `github.com` (git over HTTPS, basic
    `x-access-token`). Every other secret reaches the sandbox exactly as
    before. The per-secret `exposure` label is gate 1b.
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

  @doc """
  Split a merged secrets map into what the sandbox gets and what the broker
  gets. Runs on the merged map, so the vault-wins rule has already applied
  (ADR 0019 §9: brokering happens after the merge).

  Returns `{sandbox_secrets, brokered}` where every catalog key present is a
  placeholder in the first map and its real value is in the second. Keys with
  an empty value are left alone: there is nothing to broker.
  """
  @spec split(%{String.t() => String.t()}) ::
          {%{String.t() => String.t()}, %{String.t() => String.t()}}
  def split(secrets) when is_map(secrets) do
    Enum.reduce(secrets, {%{}, %{}}, fn {k, v}, {sandbox, brokered} ->
      if Map.has_key?(@catalog, k) and is_binary(v) and v != "" do
        {Map.put(sandbox, k, placeholder(k)), Map.put(brokered, k, v)}
      else
        {Map.put(sandbox, k, v), brokered}
      end
    end)
  end

  # The services a set of brokered keys turns into. One host per service is
  # the Agent Vault shape; `api.github.com` takes a bearer, and git over HTTPS
  # on `github.com` sends basic auth, which the broker rewrites wholesale.
  defp services_for(brokered) do
    brokered
    |> Map.keys()
    |> Enum.map(&Map.get(@catalog, &1))
    |> Enum.uniq()
    |> Enum.flat_map(fn
      :github ->
        key = github_key(brokered)

        [
          %{
            name: "github-api",
            host: "api.github.com",
            auth: %{type: "bearer", token: key}
          },
          %{
            name: "github-git",
            host: "github.com",
            auth: %{type: "basic", username: "GITHUB_BASIC_USER", password: key}
          }
        ]

      _ ->
        []
    end)
  end

  # Both names may be present after the merge; the git URL is written with
  # whichever one `repositories[].secret_key` names, and the broker needs a
  # single credential per service. Prefer the canonical name.
  defp github_key(brokered) do
    if Map.has_key?(brokered, "GITHUB_TOKEN"), do: "GITHUB_TOKEN", else: "GH_TOKEN"
  end

  # Credentials the services above reference beyond the tenant's own. The
  # basic-auth username for git is a constant GitHub documents, stored as a
  # credential because that is the only place a service may read one from.
  defp credentials_for(brokered) do
    if Enum.any?(brokered, fn {k, _} -> Map.get(@catalog, k) == :github end) do
      Map.put(brokered, "GITHUB_BASIC_USER", "x-access-token")
    else
      brokered
    end
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
  @spec prepare(String.t(), %{String.t() => String.t()}) ::
          {:ok, session()} | {:error, term()}
  def prepare(conversation_id, brokered) when is_binary(conversation_id) and is_map(brokered) do
    vault = vault_name(conversation_id)

    with :ok <- ensure_vault(vault),
         :ok <- set_policy(vault, "passthrough"),
         :ok <- put_credentials(vault, credentials_for(brokered)),
         :ok <- put_services(vault, services_for(brokered)) do
      mint_session(vault, conversation_id)
    end
  end

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
