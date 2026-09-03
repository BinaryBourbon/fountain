defmodule Fountain.Broker do
  @moduledoc """
  The egress credential broker (ADR 0019).

  A brokered conversation's sandbox holds a **placeholder** where a
  credential used to be, plus a proxy address. The real value stays in the
  DEK-encrypted rows it always lived in and is attached to the outbound
  request at a forward proxy. The sandbox's only permitted egress is the
  proxy, so a placeholder is worthless off the box.

  This module is the seam the rest of the app talks to: the catalog of
  secrets the broker knows how to carry, the placeholder rule, the split of
  a secrets map into what the sandbox gets and what the broker gets, the
  sandbox's environment, and the session lifecycle. It is the **policy**;
  the proxy that does the attaching is a **backend**, and there are two:

  | Backend | Module | Selected by |
  |---|---|---|
  | [Agent Vault](https://github.com/Infisical/agent-vault), the vendor gate 1a shipped with | `Fountain.Broker.AgentVault` | `BROKER_URL` |
  | The native proxy, `Managoat.Broker` (#1340), run inside this application | `Fountain.Broker.Native` | `BROKER_LISTEN_PORT` |

  Setting both is a boot error (`config/runtime.exs`). Every function here
  that reaches a proxy dispatches on `backend/0`; the ones that do not
  (`split/2`, `placeholder/1`, `sandbox_env/1`, `network_for/1`, ...) are
  the same whichever backend runs. The two coexist so that merging the
  native backend is inert for a deployment on Agent Vault; the flip is a
  deployment change, after which the vendor client is deleted.

  ## What is brokered

  * A secret with an enabled **binding** (`Fountain.SecretBindings`, gate 1b):
    the tenant said which host it goes to and how. One service per binding.
  * `GITHUB_TOKEN` and `GH_TOKEN` with no binding of their own, bound by the
    built-in catalog to `api.github.com` (bearer) and `github.com` (git over
    HTTPS, basic `x-access-token`) — gate 1a's default, kept so a tenant who
    never opens the bindings page keeps working.
  * The runtime's **inference credential** (gate 3): `CLAUDE_CODE_OAUTH_TOKEN`
    or `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`. The runtime
    gets a vendor-shaped placeholder and the broker substitutes the value on
    requests to the provider's host. A tenant secret of the same name with a
    binding of its own wins, as it wins in the environment.
  * Every other secret reaches the sandbox exactly as before.
  * Only tenants listed in `BROKER_TENANTS`: the operator ratchet of §9.

  ## How a value is attached

  Every service carries a **substitution** for its key: the broker replaces
  the placeholder wherever it appears in a request to that host, so the agent
  sends the shape the API wants and nothing has to be told how. A binding's
  explicit shape (bearer, api-key, custom) additionally sets a header the
  agent did not send; `basic` is the one case substitution cannot reach,
  because the client base64-encodes the value before it leaves. Agent Vault
  substitutes in the path, query, headers and body; the native proxy in
  header values only (its README lists the deviations).

  ## The network policy (gate 2)

  The sandbox's own policy is always the floor, `allow: [broker]`. What the
  environment's `networking_type` says is enforced **at the broker**:
  `unrestricted` sets the session's unmatched-host policy to `passthrough`,
  so the agent may reach any host but only ever with the credentials it was
  granted; `limited` sets it to `deny` and turns `allowed_hosts` into
  passthrough services, so an unlisted host is refused with a 403.

  ## Custody

  One broker session per **conversation**, deleted when the conversation
  ends (ADR 0019 §11 as amended). The binding is on the token: a token
  resolves to its own conversation's credentials and to nothing else.

  The session token lives `BROKER_SESSION_TTL_SECONDS` and travels to the
  sandbox inside `HTTPS_PROXY`, which is why that variable is process-only
  in `Fountain.Conversations.Identity` and never reaches the shared `.env`.

  ## Off means off

  `configured?/0` is false when neither `BROKER_URL` nor
  `BROKER_LISTEN_PORT` is set, and then no function here reaches a proxy,
  nothing listens, and provisioning is byte-for-byte what it was.
  """

  alias Fountain.Broker.{AgentVault, Native}

  @ca_path "/usr/local/share/ca-certificates/agent-vault.crt"

  # The OS trust bundle update-ca-certificates rebuilds — real roots plus the
  # broker CA install_broker_ca added. Point replacement-style CA vars here,
  # never at @ca_path alone: that is one cert, and a tool told to trust only it
  # rejects every non-brokered host (pypi, crates.io) it also has to reach.
  @system_ca_bundle "/etc/ssl/certs/ca-certificates.crt"

  @typedoc "A minted proxy session for one conversation."
  @type session :: %{
          vault: String.t(),
          token: String.t(),
          expires_at: DateTime.t() | nil
        }

  @typedoc "Which proxy attaches credentials on this deployment."
  @type backend :: :agent_vault | :native

  # ---------------------------------------------------------------------------
  # Configuration

  @doc """
  The backend this deployment runs, or nil when brokerage is off.
  `BROKER_LISTEN_PORT` selects the native proxy, `BROKER_URL` the Agent Vault
  client; boot refuses both.
  """
  @spec backend() :: backend() | nil
  def backend do
    cond do
      is_integer(Application.get_env(:fountain, :broker_listen_port)) -> :native
      is_binary(Application.get_env(:fountain, :broker_url)) -> :agent_vault
      true -> nil
    end
  end

  @doc "True when a backend is configured. Nothing here talks to a proxy otherwise."
  @spec configured?() :: boolean()
  def configured?, do: backend() != nil

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

  @doc "How long a released conversation's vault keeps its request log before the reaper deletes it (Agent Vault)."
  @spec log_retention_hours() :: pos_integer()
  def log_retention_hours, do: Application.get_env(:fountain, :broker_log_retention_hours, 168)

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

  @doc false
  # The unbound GitHub key the catalog pair is attached to, or nil when no
  # catalog key is present without bindings of its own. Both names may be
  # present after the merge; the git URL is written with whichever one
  # `repositories[].secret_key` names, and the broker needs a single
  # credential per service. Prefer the canonical name.
  @spec catalog_github_key(map(), map()) :: String.t() | nil
  def catalog_github_key(brokered, bindings) do
    unbound = fn key -> Map.has_key?(brokered, key) and not Map.has_key?(bindings, key) end

    cond do
      unbound.("GITHUB_TOKEN") -> "GITHUB_TOKEN"
      unbound.("GH_TOKEN") -> "GH_TOKEN"
      true -> nil
    end
  end

  @doc false
  # The username git over HTTPS sends beside a GitHub token.
  @spec github_basic_user() :: String.t()
  def github_basic_user, do: "x-access-token"

  @inference_prefix %{
    "CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat01-",
    "ANTHROPIC_API_KEY" => "sk-ant-api03-",
    "OPENAI_API_KEY" => "sk-",
    "GEMINI_API_KEY" => "AIza"
  }

  @doc """
  The placeholder a brokered key carries in the sandbox.

  Lowercase, wrapped in double underscores: visibly not a token, and exactly
  the string the broker's substitution looks for. An inference credential
  keeps its vendor prefix in front (`sk-ant-oat01-__claude_code_oauth_token__`)
  for a CLI that checks the shape of its own token before sending it; the
  substitution then replaces the whole prefixed string.
  """
  @spec placeholder(String.t()) :: String.t()
  def placeholder(key) do
    Map.get(@inference_prefix, key, "") <> "__" <> String.downcase(key) <> "__"
  end

  # Inference credentials (gate 3): the env var each runtime reads, the host
  # it talks to, and the prefix its vendor's tokens carry. Substitution
  # rewrites the placeholder wherever it appears in a **header value**, which
  # is every shape these runtimes actually send — Anthropic's `x-api-key`, the
  # OAuth bearer, OpenAI's bearer, Gemini's `x-goog-api-key`.
  #
  # This comment used to claim substitution also covered "Gemini's `?key=`
  # query parameter". It does not, on either backend that matters:
  # `Fountain.Broker.Native` substitutes in header values only, where Agent
  # Vault also rewrote path, query and body (#1359 row 1). Measured 2026-09-03
  # against gemini-cli 0.58.0 — the sandbox images pin no version, so this is
  # what a sandbox runs — by hooking `fetch` under the sandbox's own env
  # (`GEMINI_API_KEY` set, no base-URL override, so `getAuthTypeFromEnv`
  # resolves `gemini-api-key`): every call to generativelanguage.googleapis.com
  # carries the key in `x-goog-api-key` and nothing in the query string. The
  # `?key=` form is real but belongs to the Live API's audio and music
  # WebSockets, which an ACP turn never opens. Header substitution is therefore
  # sufficient for Gemini and query substitution is not needed for the flip.
  #
  # Note `GOOGLE_GEMINI_BASE_URL` outranks `GEMINI_API_KEY` in that
  # resolution, so pointing the CLI at a local capture changes the auth type
  # out from under the measurement. Hook the client, do not redirect it.
  @inference %{
    "CLAUDE_CODE_OAUTH_TOKEN" => %{cred: :claude_code_oauth_token, hosts: ["api.anthropic.com"]},
    "ANTHROPIC_API_KEY" => %{cred: :anthropic_api_key, hosts: ["api.anthropic.com"]},
    "OPENAI_API_KEY" => %{cred: :openai_api_key, hosts: ["api.openai.com"]},
    "GEMINI_API_KEY" => %{cred: :gemini_api_key, hosts: ["generativelanguage.googleapis.com"]}
  }

  @doc "The env var names that carry inference credentials, and the credential each comes from."
  @spec inference_keys() :: %{String.t() => atom()}
  def inference_keys, do: Map.new(@inference, fn {k, v} -> {k, v.cred} end)

  @doc """
  Split the runtime's inference credentials (gate 3): the map handed to
  `default_env/2` gets placeholders, the broker gets the values under the
  env var names, and each gets an implicit `substitute` binding to its
  provider's host. A tenant's own binding for the same name wins.
  """
  @spec split_inference(map(), bindings()) :: {map(), %{String.t() => String.t()}, bindings()}
  def split_inference(credentials, bindings \\ %{}) when is_map(credentials) do
    Enum.reduce(@inference, {credentials, %{}, %{}}, fn {key, %{cred: cred, hosts: hosts}},
                                                        {creds, brokered, implicit} ->
      case Map.get(creds, cred) do
        value when is_binary(value) and value != "" ->
          implicit =
            if Map.has_key?(bindings, key),
              do: implicit,
              else: Map.put(implicit, key, Enum.map(hosts, &implicit_binding(key, &1)))

          {Map.put(creds, cred, placeholder(key)), Map.put(brokered, key, value), implicit}

        _ ->
          {creds, brokered, implicit}
      end
    end)
  end

  defp implicit_binding(key, host) do
    %Fountain.SecretBindings.Binding{
      key: key,
      host: host,
      auth_type: "substitute",
      headers: %{},
      enabled: true
    }
  end

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

  The CA variables make each toolchain trust the broker's MITM certificate.
  `install_broker_ca` puts the CA in the OS trust store, which curl, git and
  anything on OpenSSL then read — but a tool with its own bundled roots does
  not. Node is told through `NODE_EXTRA_CA_CERTS` (additive, so the broker CA
  alone); the rest replace their bundle and so must name the full system bundle
  (`@system_ca_bundle`), not the broker CA on its own. `UV_NATIVE_TLS` turns uv
  off its bundled webpki roots and onto that same OS store. Without these, a
  brokered `uv sync`, `pip install`, or `cargo fetch` fails with
  `invalid peer certificate: UnknownIssuer` the moment it reaches a MITM'd host.
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
      {"NODE_EXTRA_CA_CERTS", @ca_path},
      {"SSL_CERT_FILE", @system_ca_bundle},
      {"REQUESTS_CA_BUNDLE", @system_ca_bundle},
      {"CARGO_HTTP_CAINFO", @system_ca_bundle},
      {"UV_NATIVE_TLS", "1"}
    ]
  end

  @doc "Every variable `sandbox_env/1` sets, for a refresh to replace."
  @spec env_keys() :: [String.t()]
  def env_keys,
    do:
      ~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE CARGO_HTTP_CAINFO UV_NATIVE_TLS)

  @doc "The variables that carry the session token, which `Identity` keeps off the shared `.env`."
  @spec process_only_keys() :: [String.t()]
  def process_only_keys, do: ~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy)

  # Both userinfo fields, on purpose (gate 0): with the token alone curl is
  # happy and git stops to ask for a *proxy* password. Agent Vault reads
  # `Basic base64(token:vault)` and requires the vault to match the token's;
  # the native proxy reads the token and ignores the vault half.
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

  @typedoc "What the environment's `networking_type` asks for: reach anything, or only these hosts."
  @type network :: :unrestricted | {:limited, [String.t()]}

  @doc "The network shape an environment asks for, as `prepare/4` takes it."
  @spec network_for(map() | nil) :: network()
  def network_for(%{networking_type: "limited", networking_config: config}) do
    {:limited, (config && (config["allowed_hosts"] || config[:allowed_hosts])) || []}
  end

  def network_for(_), do: :unrestricted

  @doc "The conversation id a vault name was made from, or nil for a vault that is not ours."
  @spec conversation_id_for_vault(String.t()) :: String.t() | nil
  def conversation_id_for_vault("c-" <> hex) when byte_size(hex) == 32 do
    case Ecto.UUID.cast(
           String.replace(hex, ~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
         ) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  def conversation_id_for_vault(_), do: nil

  # ---------------------------------------------------------------------------
  # Calls to the backend. Each returns `:ok`/`{:ok, _}` or `{:error, reason}`;
  # retries belong to the caller, per the repo's client convention.

  @doc "Is the broker up? The preflight; a failure here stops provisioning before a sandbox exists."
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    case backend() do
      nil -> {:error, {:broker, :unreachable, :not_configured}}
      backend -> impl(backend).preflight()
    end
  end

  @doc "The root CA the proxy signs with. The sandbox trusts it or nothing works."
  @spec ca_pem() :: {:ok, binary()} | {:error, term()}
  def ca_pem do
    case backend() do
      nil -> {:error, {:broker, :ca, :not_configured}}
      backend -> impl(backend).ca_pem()
    end
  end

  @doc """
  Make the broker ready for one conversation and mint its session.

  Idempotent, and run on every provision and reattach, so an edited secret
  or binding reaches the broker on the next wake, the same way the `.env`
  file is refreshed. `opts`: `network:` (`network_for/1`), and `user_id:`,
  which the native backend needs to reach the tenant's key and looks up
  from the conversation when the caller has not got it to hand.
  """
  @spec prepare(String.t(), %{String.t() => String.t()}, bindings(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings \\ %{}, opts \\ [])
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    case backend() do
      nil -> {:error, {:broker, :session, :not_configured}}
      backend -> impl(backend).prepare(conversation_id, brokered, bindings, opts)
    end
  end

  @doc """
  Release a conversation's session at the end of its life, so nothing
  brokers on its behalf again. On Agent Vault the vault itself stays for
  its request log (gate 4) until `Fountain.Workers.BrokerVaultReaper`
  deletes it; on the native backend the session rows go at once.
  """
  @spec release(String.t()) :: :ok | {:error, term()}
  def release(conversation_id) when is_binary(conversation_id) do
    case backend() do
      nil -> :ok
      backend -> impl(backend).release(conversation_id)
    end
  end

  @doc "Delete a vault outright, log and all. The reaper's call, never provisioning's. Agent Vault only."
  @spec delete_vault(String.t()) :: :ok | {:error, term()}
  def delete_vault(vault) when is_binary(vault) do
    case backend() do
      :agent_vault -> AgentVault.delete_vault(vault)
      _ -> :ok
    end
  end

  @doc "Every vault on the broker, by name. Agent Vault only; the native backend has none."
  @spec list_vaults() :: {:ok, [String.t()]} | {:error, term()}
  def list_vaults do
    case backend() do
      :agent_vault -> AgentVault.list_vaults()
      _ -> {:ok, []}
    end
  end

  @typedoc "One outbound request the broker handled for a conversation."
  @type egress_event :: %{
          id: integer(),
          at: DateTime.t() | nil,
          method: String.t(),
          host: String.t(),
          path: String.t(),
          service: String.t() | nil,
          credential_keys: [String.t()],
          status: integer() | nil,
          latency_ms: integer() | nil,
          error: String.t() | nil
        }

  @doc """
  The broker's request log for a conversation, newest first (gate 4): what
  actually left the sandbox, to which host, with which credential attached,
  and what came back. `before:` pages by the previous page's oldest `id`.
  The native backend keeps no stored log yet and answers an empty page; its
  request log is the `[:managoat, :broker, :request]` telemetry and the
  log line `Fountain.Broker.Native` writes from it.
  """
  @spec request_log(String.t(), keyword()) ::
          {:ok, %{events: [egress_event()], next: integer() | nil}} | {:error, term()}
  def request_log(conversation_id, opts \\ []) when is_binary(conversation_id) do
    case backend() do
      nil -> {:error, {:broker, :request_log, :not_configured}}
      backend -> impl(backend).request_log(conversation_id, opts)
    end
  end

  defp impl(:agent_vault), do: AgentVault
  defp impl(:native), do: Native
end
