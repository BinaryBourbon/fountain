defmodule Fountain.Conversations.McpServers do
  @moduledoc """
  The MCP server list a runtime receives at `session/new`.

  Two halves. The agent-declared servers, with their `${VAR}` references
  resolved against the environment and the secrets (`substitute_agent/3`),
  and the ones Fountain serves back to the sandbox itself, authenticated with
  the conversation's callback token (`Fountain.Conversations.CallbackKey`):
  the Buzz reply tools, the team tools, a teammate's comms tools and the
  caller-tool bridge. Each of those decides for itself whether this
  conversation gets it; `fountain_served/2` only asks, in the order the
  server has always appended them.

  Functions over rows and values, not over server state: `ConversationServer`
  unpacks what it holds and passes it in (#1369). Nothing here touches the
  database directly; the Fountain-served lists read the conversation row
  through the context that owns each tool set.
  """

  alias Fountain.Agents.Agent
  alias Fountain.Environments.Environment
  alias Managoat.Substitution

  # Resolve `${VAR}` references in the agent's MCP server config against
  # env_vars + env_secrets + vault_secrets (vault wins). Env vars values
  # are coerced to strings; non-string values further down the tree pass
  # through untouched.
  @spec substitute_agent(Agent.t() | nil, Environment.t() | nil, map()) ::
          {:ok, Agent.t() | nil} | {:error, term()}
  def substitute_agent(nil, _env, _secrets), do: {:ok, nil}

  def substitute_agent(agent, env, secrets) do
    vars = substitution_vars(env, secrets)

    case Substitution.apply(agent.mcp_servers || %{}, vars) do
      {:ok, mcp} -> {:ok, %{agent | mcp_servers: mcp}}
      {:error, _} = err -> err
    end
  end

  @doc """
  The variables `${VAR}` resolves against: the environment's `env_vars` with
  keys and values as strings, overridden by the decrypted `secrets`.
  """
  @spec substitution_vars(Environment.t() | nil, map()) :: map()
  def substitution_vars(env, secrets) do
    env_vars =
      if env,
        do: Map.new(env.env_vars || %{}, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: %{}

    Map.merge(env_vars, secrets)
  end

  @doc """
  The Fountain-served servers for a turn, in the order the server has always
  appended them after the agent's own: buzz, team, team comms, caller.
  """
  @spec fountain_served(map(), String.t() | nil) :: [map()]
  def fountain_served(%{id: conv_id} = conv, token) do
    buzz(conv_id, token) ++
      team(conv_id, token) ++
      team_comms(conv_id, token) ++
      caller(conv, token)
  end

  # The Buzz reply tools (#737), injected into `session/new` only for a
  # Buzz-driven conversation and only once a callback token has been minted —
  # `Fountain.Buzz` decides both. `[]` for every other conversation.
  @spec buzz(String.t() | nil, String.t() | nil) :: [map()]
  def buzz(conv_id, token) when is_binary(token) and is_binary(conv_id) do
    Fountain.Buzz.conversation_mcp_servers(conv_id, token)
  end

  def buzz(_conv_id, _token), do: []

  # The team tools (#851), for conversations on the team channel.
  @spec team(String.t() | nil, String.t() | nil) :: [map()]
  def team(conv_id, token) when is_binary(token) and is_binary(conv_id),
    do: Fountain.Team.conversation_mcp_servers(conv_id, token)

  def team(_conv_id, _token), do: []

  # A teammate's email + phone tools (flag `team_comms`), injected the same
  # way: only for a team conversation whose teammate has a contact, and only
  # once a callback token exists — `Fountain.Team.Comms` decides. Computed
  # at every turn kick, so a contact given mid-session is there next turn.
  @spec team_comms(String.t() | nil, String.t() | nil) :: [map()]
  def team_comms(conv_id, token) when is_binary(token) and is_binary(conv_id) do
    Fountain.Team.Comms.conversation_mcp_servers(conv_id, token)
  end

  def team_comms(_conv_id, _token), do: []

  # The caller-tool bridge (#1202): the tools a chat-completions or AG-UI
  # client defined, served back to the sandbox as one more MCP server. Read
  # off the conversation row at every turn kick, so a list registered by the
  # request that opened this turn is on it.
  @spec caller(map(), String.t() | nil) :: [map()]
  def caller(conv, token) when is_binary(token),
    do: Fountain.CallerTools.conversation_mcp_servers(conv, token)

  def caller(_conv, _token), do: []
end
