defmodule Fountain.Broker.AgentVault do
  @moduledoc """
  The [Agent Vault](https://github.com/Infisical/agent-vault) backend of
  `Fountain.Broker` (ADR 0019 gate 1a, §8): the vendor's HTTP client, moved
  here unchanged from `Fountain.Broker` when the native backend arrived
  (#1340). Selected by `BROKER_URL`.

  The real value lives in an Agent Vault instance, loaded from the same
  DEK-encrypted rows it always lived in, into a vault per conversation
  (`c-<conversation id>`), and is attached to the outbound request at the
  vendor's proxy. The session token is minted with the `proxy` vault role
  (it may broker, never read).

  The vault stays after `release/1` because its request log is the effect
  half of the audit trail (gate 4); `Fountain.Workers.BrokerVaultReaper`
  deletes it once the log is past `BROKER_LOG_RETENTION_HOURS`.

  Production runs this backend for one tenant today. It is deleted in the
  PR after the deployment flips to `Fountain.Broker.Native`.
  """

  alias Fountain.Broker

  require Logger

  # ---------------------------------------------------------------------------
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
      case Broker.catalog_github_key(brokered, bindings) do
        nil ->
          []

        key ->
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
      name: Broker.service_name(key, binding.host),
      host: binding.host,
      auth: auth,
      substitutions: [substitution(key)]
    }
  end

  # The placeholder, replaced on every surface the broker can reach. Present
  # on every service so "the placeholder anywhere" holds whatever the shape.
  defp substitution(key) do
    %{key: key, placeholder: Broker.placeholder(key), in: ~w(path query header body websocket)}
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
      |> Enum.filter(&(&1 in Broker.catalog_keys() and not Map.has_key?(bindings, &1)))
      |> Map.new(fn key -> {basic_user_key(key), Broker.github_basic_user()} end)

    brokered |> Map.merge(from_bindings) |> Map.merge(from_catalog)
  end

  # ---------------------------------------------------------------------------
  # Calls to the broker. Each returns `:ok`/`{:ok, _}` or `{:error, reason}`;
  # retries belong to the caller, per the repo's client convention.

  @doc "Is the broker up? A `false` here fails provisioning before a sandbox exists."
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    case Req.get(req(auth: false), url: "/health") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:broker, :unreachable, {status, body}}}
      {:error, reason} -> {:error, {:broker, :unreachable, reason}}
    end
  end

  @doc "The root CA the proxy signs with, fetched from the broker."
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
  are upserted, and a fresh session is minted every call.
  """
  @spec prepare(String.t(), %{String.t() => String.t()}, Broker.bindings(), keyword()) ::
          {:ok, Broker.session()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings, opts)
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    vault = Broker.vault_name(conversation_id)
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
      %{name: Broker.service_name("ALLOW", host), host: host, auth: %{type: "passthrough"}}
    end)
  end

  @doc """
  Release a conversation's vault at the end of its life: every credential,
  service and session goes, so nothing brokers on its behalf again — but
  the vault itself stays, because its request log is the effect half of the
  audit trail (gate 4) and deleting the vault would take it. A missing vault
  is already released.
  """
  @spec release(String.t()) :: :ok | {:error, term()}
  def release(conversation_id) when is_binary(conversation_id) do
    vault = Broker.vault_name(conversation_id)

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

  @doc """
  The broker's request log for a conversation, newest first (gate 4).
  `before:` pages by the previous page's oldest `id`.
  """
  @spec request_log(String.t(), keyword()) ::
          {:ok, %{events: [Broker.egress_event()], next: integer() | nil}} | {:error, term()}
  def request_log(conversation_id, opts) when is_binary(conversation_id) do
    vault = Broker.vault_name(conversation_id)

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

  # A duplicate name is 409 by the broker's contract, but Agent Vault was
  # seen answering 500 "Failed to create vault" for one on prod
  # (2026-08-25), which failed every reattach of a brokered conversation
  # after its first idle. A refused create is therefore checked against the
  # vault list before it counts as a failure: the vault we wanted is there,
  # and that is all `ensure` promises.
  defp ensure_vault(vault) do
    case Req.post(req(), url: "/v1/vaults", json: %{name: vault}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 409}} ->
        :ok

      other ->
        case list_vaults() do
          {:ok, names} ->
            if vault in names, do: :ok, else: {:error, {:broker, :vault, normalize(other)}}

          {:error, _} ->
            {:error, {:broker, :vault, normalize(other)}}
        end
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
