defmodule Fountain.Conversations.Egress do
  @moduledoc """
  Everything ADR 0019 wired into a conversation: which secrets are brokered,
  the connections that contribute tokens, the proxy session's life, and the
  network floor.

  Talks to `Fountain.Broker` (the facade over its backends since #1357,
  never a backend) and `Fountain.Connections`. Functions over rows and
  values, not over server state (#1369): `ConversationServer` keeps the
  fields the session, its placeholders and its bindings live in, unpacks
  them for each call and applies what comes back. The three places that
  change more than one field at once (mint, the OAuth switch, the refresh
  before a turn) are the server's short wrappers over `prepare/4`,
  `drop_oauth_token/3` and `reprepare/5`.

  The split rules, in order, as the server applies them at provision:
  `bindings/1`, `add_connection_secrets/4`, `split_brokered/3`,
  `split_inference/4`. Each is a no-op for an unbrokered tenant.
  """

  alias Fountain.Broker
  alias Fountain.Conversations.Provisioning

  @typedoc "A proxy session as `Fountain.Broker.prepare/4` returns it, or nil when the conversation has none."
  @type session :: map() | nil

  @doc "Whether this tenant's conversations are brokered: `Fountain.Broker.enabled_for?/1`."
  @spec brokered?(String.t() | nil) :: boolean()
  def brokered?(user_id), do: Broker.enabled_for?(user_id)

  # On a brokered conversation the catalog keys leave the secrets map here,
  # before the MCP substitution and the env are built from it, so both see
  # the placeholder and neither sees the value.
  @spec split_brokered(String.t(), map(), Broker.bindings()) :: {map(), map()}
  def split_brokered(user_id, secrets, bindings) do
    if Broker.enabled_for?(user_id),
      do: Broker.split(secrets, bindings),
      else: {secrets, %{}}
  end

  # A tenant's connections (#1178) contribute their access tokens as
  # synthetic secrets, brokered like inference keys: the sandbox gets a
  # placeholder, the broker gets the value with an implicit bearer binding
  # to the provider's hosts. A tenant's own secret of the same name wins,
  # as does their own binding on it (which is how the token reaches an MCP
  # server they run). Only for brokered tenants — without the broker the
  # token would have to enter the sandbox in the clear, which is the thing
  # connections exist to avoid.
  @spec add_connection_secrets(String.t(), map(), Broker.bindings(), map() | nil) ::
          {map(), Broker.bindings(), [String.t()]}
  def add_connection_secrets(user_id, merged, bindings, agent) do
    if Broker.enabled_for?(user_id) do
      connections = active_connections_by_id(user_id)
      synthetic = Fountain.Connections.synthetic_secrets(user_id)
      remote_hosts = remote_connection_hosts(agent, connections)

      {merged, bindings, keys} =
        Enum.reduce(synthetic, {merged, bindings, []}, fn {key, token}, {m, b, keys} ->
          if Map.has_key?(m, key) do
            {m, b, keys}
          else
            b =
              if Map.has_key?(b, key),
                do: b,
                else: Map.put(b, key, connection_bindings(user_id, key, remote_hosts))

            {Map.put(m, key, token), b, [key | keys]}
          end
        end)

      {merged, bindings, Enum.sort(keys)}
    else
      {merged, bindings, []}
    end
  end

  # The provider's own hosts, plus the host of every remote MCP server the
  # agent attaches with this connection (#1186): the broker attaches the
  # bearer to exactly those and nothing else.
  @spec connection_bindings(String.t(), String.t(), %{String.t() => [String.t()]}) ::
          [Fountain.SecretBindings.Binding.t()]
  def connection_bindings(user_id, key, remote_hosts) do
    (Fountain.Connections.implicit_hosts(user_id, key) ++ Map.get(remote_hosts, key, []))
    |> Enum.uniq()
    |> Enum.map(fn host ->
      %Fountain.SecretBindings.Binding{
        key: key,
        host: host,
        auth_type: "bearer",
        headers: %{},
        enabled: true
      }
    end)
  end

  defp active_connections_by_id(user_id) do
    user_id
    |> Fountain.Connections.active_connections()
    |> Map.new(&{&1.id, &1})
  end

  defp remote_connection_hosts(%{mcp_servers: servers}, connections) when is_map(servers),
    do: Fountain.Connections.McpServers.remote_hosts(servers, connections)

  defp remote_connection_hosts(_agent, _connections), do: %{}

  # Re-read the brokered connection tokens; a rotated one is swapped into
  # `brokered` and the caller re-prepares the vault. A refresh that fails
  # leaves the old token in place: the turn runs on it and, if it has
  # expired, fails at the provider with a reason rather than silently here.
  @spec refresh_connection_secrets([String.t()], String.t(), map()) :: {map(), boolean()}
  def refresh_connection_secrets([], _user_id, brokered), do: {brokered, false}

  def refresh_connection_secrets(keys, user_id, brokered) do
    fresh = user_id |> Fountain.Connections.synthetic_secrets() |> Map.take(keys)

    rotated =
      Enum.filter(fresh, fn {k, v} -> Map.get(brokered, k) != v end)

    if rotated == [] do
      {brokered, false}
    else
      {Map.merge(brokered, Map.new(rotated)), true}
    end
  end

  # An agent whose `mcp_servers` names a connection gets the entry rewritten
  # into the Fountain-served server (#1178), authenticated by the
  # conversation's callback token. Not for an unbrokered tenant: the entry
  # is dropped and the agent runs without it.
  @spec with_connection_servers(map() | nil, String.t(), String.t(), String.t() | nil) ::
          map() | nil
  def with_connection_servers(agent, user_id, conversation_id, callback_token)

  def with_connection_servers(nil, _user_id, _conversation_id, _callback_token), do: nil

  def with_connection_servers(%{mcp_servers: servers} = agent, user_id, conversation_id, token)
      when is_map(servers) do
    brokered = Broker.enabled_for?(user_id)
    token = if brokered, do: token
    connections = if brokered, do: active_connections_by_id(user_id), else: %{}

    %{
      agent
      | mcp_servers:
          Fountain.Connections.McpServers.resolve(
            servers,
            conversation_id,
            token,
            connections
          )
    }
  end

  def with_connection_servers(agent, _user_id, _conversation_id, _callback_token), do: agent

  # Only read for a brokered tenant: for everyone else the table is rows
  # nobody consults, and this path stays free of a query.
  @spec bindings(String.t()) :: Broker.bindings()
  def bindings(user_id) do
    if Broker.enabled_for?(user_id),
      do: Fountain.SecretBindings.enabled_by_key(user_id),
      else: %{}
  end

  # Gate 3: the runtime is handed placeholders for its inference credentials
  # and the broker gets the values, with an implicit binding to the provider's
  # host. A tenant's own secret of the same name (already split above) wins
  # over the inference credential, as it wins in the environment.
  @spec split_inference(String.t(), map(), map(), Broker.bindings()) ::
          {map(), map(), Broker.bindings()}
  def split_inference(user_id, inference_creds, brokered, bindings) do
    if Broker.enabled_for?(user_id) do
      {env_creds, inference_brokered, implicit} =
        Broker.split_inference(inference_creds, bindings)

      {env_creds, Map.merge(inference_brokered, brokered), Map.merge(implicit, bindings)}
    else
      {inference_creds, brokered, bindings}
    end
  end

  @doc "The proxy variables a session puts in the sandbox's env; none without a session."
  @spec sandbox_env(session()) :: [{String.t(), String.t()}]
  def sandbox_env(nil), do: []
  def sandbox_env(session), do: Broker.sandbox_env(session)

  @doc """
  Mint (or re-mint) the conversation's proxy session, publishing the
  `broker` stage around it. The caller decides whether the conversation is
  brokered at all (`brokered?/1`) and holds the session that comes back.
  """
  @spec prepare(String.t(), map(), Broker.bindings(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings, opts) do
    publish_stage(conversation_id, "broker", "started", %{
      keys: brokered |> Map.keys() |> Enum.sort()
    })

    case Broker.prepare(conversation_id, brokered, bindings, opts) do
      {:ok, session} ->
        publish_stage(conversation_id, "broker", "done", %{
          vault: session.vault,
          expires_at: session.expires_at
        })

        {:ok, session}

      {:error, reason} ->
        publish_stage(conversation_id, "broker", "failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  @doc """
  The OAuth token was refused: forget it on both sides, so the API key is
  what the substitution carries. Returns the runtime's credentials, the
  brokered map and the bindings without it; the caller then `reprepare/5`s.
  """
  @spec drop_oauth_token(map(), map(), Broker.bindings()) :: {map(), map(), Broker.bindings()}
  def drop_oauth_token(inference_credentials, brokered, bindings) do
    creds = Map.delete(inference_credentials, :claude_code_oauth_token)

    {env_creds, inference_brokered, implicit} =
      Broker.split_inference(creds, bindings)

    brokered =
      brokered
      |> Map.delete("CLAUDE_CODE_OAUTH_TOKEN")
      |> Map.merge(inference_brokered)

    bindings =
      bindings |> Map.delete("CLAUDE_CODE_OAUTH_TOKEN") |> Map.merge(implicit)

    {env_creds, brokered, bindings}
  end

  @doc """
  Replace the session and rebuild the env with the new token; everything
  else in the env is unchanged. No stage is published: this is the refresh
  before a turn and the re-prepare after an OAuth refusal, not provisioning.
  """
  @spec reprepare(String.t(), map(), Broker.bindings(), [{String.t(), String.t()}], keyword()) ::
          {:ok, map(), [{String.t(), String.t()}]} | {:error, term()}
  def reprepare(conversation_id, brokered, bindings, sprite_env, opts) do
    case Broker.prepare(conversation_id, brokered, bindings, opts) do
      {:ok, session} ->
        keys = Broker.env_keys()
        kept = Enum.reject(sprite_env, fn {k, _} -> to_string(k) in keys end)
        {:ok, session, kept ++ Broker.sandbox_env(session)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Install the broker's CA into the sandbox; nothing to install without a session."
  @spec install_ca(session(), Managoat.Sandbox.Handle.t(), String.t()) :: :ok | {:error, term()}
  def install_ca(nil, _handle, _conversation_id), do: :ok

  def install_ca(_session, handle, conversation_id),
    do: Provisioning.install_broker_ca(handle, conversation_id)

  # Every session of the conversation goes when its sandbox does. Still off
  # the caller's path: deleting rows is local and cannot fail the way a call
  # to a vendor proxy could, but teardown is not a place to start waiting on
  # the database either, and a broker session that outlives its sandbox is
  # swept by `Fountain.Workers.BrokerReaper` regardless.
  @spec release(String.t() | nil, String.t()) :: :ok
  def release(user_id, conversation_id) do
    if Broker.enabled_for?(user_id) do
      conv_id = conversation_id
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn -> Broker.release(conv_id) end)
    end

    :ok
  end

  @doc "The network floor: the environment's policy, or the broker's when brokered."
  @spec apply_policy(Managoat.Sandbox.Handle.t(), map() | nil, String.t(), boolean()) ::
          :ok | {:error, term()}
  def apply_policy(handle, env, conv_id, false),
    do: Provisioning.apply_network_policy(handle, env, conv_id)

  def apply_policy(handle, _env, conv_id, true),
    do: Provisioning.apply_broker_floor(handle, conv_id)

  defp publish_stage(conv_id, stage, status, meta) do
    Fountain.Conversations.publish_stage(conv_id, stage, status, meta)
  end
end
