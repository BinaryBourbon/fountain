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
  * The runtime's **inference credential** (gate 3): `CLAUDE_CODE_OAUTH_TOKEN`
    or `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`. The runtime
    gets a vendor-shaped placeholder and the broker substitutes the value on
    requests to the provider's host. A tenant secret of the same name with a
    binding of its own wins, as it wins in the environment.
  * Every other secret reaches the sandbox exactly as before.

  ## How a value is attached

  Every service carries a **substitution** for its key: the broker replaces
  the placeholder wherever it appears in a request to that host — header,
  query, path, body — so the agent sends the shape the API wants and nothing
  has to be told how. A binding's explicit shape (bearer, api-key, custom)
  additionally sets a header the agent did not send; `basic` is the one case
  substitution cannot reach, because the client base64-encodes the value
  before it leaves.

  ## The network policy (gate 2, built)

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

  @doc "How long a released conversation's vault keeps its request log before the reaper deletes it."
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
  # it talks to, and the prefix its vendor's tokens carry. Substitution covers
  # every shape at once — Anthropic's `x-api-key`, the OAuth bearer, OpenAI's
  # bearer and Gemini's `?key=` query parameter alike.
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
          %{
            name: "github-api",
            host: "api.github.com",
            auth: %{type: "bearer", token: key},
            substitutions: [substitution(key)]
          },
          %{
            name: "github-git",
            host: "github.com",
            auth: %{type: "basic", username: basic_user_key(key), password: key},
            substitutions: [substitution(key)]
          }
        ]
      else
        []
      end

    merge_by_host(bound ++ catalog)
  end

  # The broker matches exactly one service per host, so two keys bound to
  # the same host must share one entry: the first declared keeps its name
  # and auth shape, and the substitutions of every key are carried together.
  # Found live: an account with both an Anthropic API key and an OAuth token
  # got two services for api.anthropic.com, the API-key one won, and the
  # OAuth placeholder went through unreplaced — a 401.
  defp merge_by_host(services) do
    services
    |> Enum.reduce([], fn svc, acc ->
      case Enum.find_index(acc, &(&1.host == svc.host)) do
        nil ->
          acc ++ [svc]

        i ->
          List.update_at(acc, i, fn kept ->
            subs = Enum.uniq_by(kept.substitutions ++ svc.substitutions, & &1.key)
            auth = if kept.auth == %{type: "passthrough"}, do: svc.auth, else: kept.auth
            %{kept | substitutions: subs, auth: auth}
          end)
      end
    end)
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
        "substitute" -> %{type: "passthrough"}
        "bearer" -> %{type: "bearer", token: key}
        "basic" -> %{type: "basic", username: basic_user_key(key), password: key}
        "api_key" -> %{type: "api-key", key: key, header: binding.header, prefix: binding.prefix}
        "custom" -> %{type: "custom", headers: binding.headers}
      end
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    %{
      name: service_name(key, binding.host),
      host: binding.host,
      auth: auth,
      substitutions: [substitution(key)]
    }
  end

  # The placeholder, replaced on every surface the broker can reach. Present
  # on every service so "the placeholder anywhere" holds whatever the shape.
  defp substitution(key) do
    %{key: key, placeholder: placeholder(key), in: ~w(path query header body websocket)}
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

  @doc """
  Release a conversation's vault at the end of its life: every credential,
  service and session goes, so nothing brokers on its behalf again — but
  the vault itself stays, because its request log is the effect half of the
  audit trail (gate 4) and deleting the vault would take it. A missing vault
  is already released. `Fountain.Workers.BrokerVaultReaper` deletes the vault
  once the log is past `BROKER_LOG_RETENTION_HOURS`.
  """
  @spec release(String.t()) :: :ok | {:error, term()}
  def release(conversation_id) when is_binary(conversation_id) do
    vault = vault_name(conversation_id)

    with {:ok, true} <- vault_exists?(vault),
         :ok <- revoke_sessions(vault),
         :ok <- clear_services(vault),
         :ok <- clear_credentials(vault) do
      :ok
    else
      {:ok, false} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Delete a vault outright, log and all. The reaper's call, never provisioning's."
  @spec delete_vault(String.t()) :: :ok | {:error, term()}
  def delete_vault(vault) when is_binary(vault) do
    case Req.delete(req(), url: "/v1/vaults/#{vault}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      other -> {:error, {:broker, :delete_vault, normalize(other)}}
    end
  end

  @doc "Every vault on the broker, by name. The owner token sees them all."
  @spec list_vaults() :: {:ok, [String.t()]} | {:error, term()}
  def list_vaults do
    case Req.get(req(), url: "/v1/vaults") do
      {:ok, %{status: 200, body: %{"vaults" => vaults}}} -> {:ok, Enum.map(vaults, & &1["name"])}
      other -> {:error, {:broker, :list_vaults, normalize(other)}}
    end
  end

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
  """
  @spec request_log(String.t(), keyword()) ::
          {:ok, %{events: [egress_event()], next: integer() | nil}} | {:error, term()}
  def request_log(conversation_id, opts \\ []) when is_binary(conversation_id) do
    vault = vault_name(conversation_id)

    params =
      [limit: Keyword.get(opts, :limit, 100)] ++ if(b = opts[:before], do: [before: b], else: [])

    case Req.get(req(), url: "/v1/vaults/#{vault}/logs", params: params) do
      {:ok, %{status: 200, body: %{"logs" => logs} = body}} ->
        {:ok, %{events: Enum.map(logs, &egress_event/1), next: body["next_cursor"]}}

      {:ok, %{status: 404}} ->
        {:ok, %{events: [], next: nil}}

      other ->
        {:error, {:broker, :request_log, normalize(other)}}
    end
  end

  defp egress_event(row) do
    %{
      id: row["id"],
      at: parse_time(row["created_at"]),
      method: row["method"],
      host: row["host"],
      path: row["path"],
      service: presence(row["matched_service"]),
      credential_keys: row["credential_keys"] || [],
      status: row["status"],
      latency_ms: row["latency_ms"],
      error: presence(row["error_code"])
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v), do: v

  defp vault_exists?(vault) do
    case Req.get(req(), url: "/v1/vaults/#{vault}/settings") do
      {:ok, %{status: 200}} -> {:ok, true}
      {:ok, %{status: 404}} -> {:ok, false}
      other -> {:error, {:broker, :release, normalize(other)}}
    end
  end

  defp revoke_sessions(vault) do
    with {:ok, %{status: 200, body: %{"sessions" => sessions}}} <-
           Req.get(req(), url: "/v1/sessions", params: [vault: vault]) do
      Enum.reduce_while(sessions, :ok, fn %{"id" => id}, :ok ->
        case Req.delete(req(), url: "/v1/sessions/#{id}", params: [vault: vault]) do
          {:ok, %{status: status}} when status in 200..299 or status == 404 -> {:cont, :ok}
          other -> {:halt, {:error, {:broker, :release, normalize(other)}}}
        end
      end)
    else
      other -> {:error, {:broker, :release, normalize(other)}}
    end
  end

  defp clear_services(vault) do
    case Req.delete(req(), url: "/v1/vaults/#{vault}/services") do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      other -> {:error, {:broker, :release, normalize(other)}}
    end
  end

  defp clear_credentials(vault) do
    with {:ok, %{status: 200, body: %{"keys" => keys}}} <-
           Req.get(req(), url: "/v1/credentials", params: [vault: vault]) do
      if keys == [] do
        :ok
      else
        case Req.delete(req(), url: "/v1/credentials", json: %{vault: vault, keys: keys}) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          other -> {:error, {:broker, :release, normalize(other)}}
        end
      end
    else
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
