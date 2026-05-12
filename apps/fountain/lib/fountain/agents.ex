defmodule Fountain.Agents do
  @moduledoc "Context for agent definitions."

  import Ecto.Query, only: [from: 2]

  alias Fountain.Agents.Agent
  alias Fountain.Agents.AgentAvatar
  alias Fountain.Conversations.Conversation
  alias Fountain.Repo

  @doc """
  WARNING: returns agents across all tenants. Admin/internal use only.
  User-facing code must use the arity-2 variant that takes user_id.
  """
  def _unsafe_list_agents(filters \\ []) do
    from(a in Agent, order_by: [desc: a.inserted_at, desc: a.id], preload: [:environment])
    |> apply_search(Keyword.get(filters, :search, ""))
    |> apply_runtimes(Keyword.get(filters, :runtimes, []))
    |> apply_env_ids(Keyword.get(filters, :env_ids, []))
    |> apply_has_skills(Keyword.get(filters, :has_skills, false))
    |> apply_has_mcp(Keyword.get(filters, :has_mcp, false))
    |> Repo.all()
  end

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_agent(id), do: Repo.get(Agent, id) |> Repo.preload(:environment)

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_agent!(id), do: Repo.get!(Agent, id) |> Repo.preload(:environment)

  @doc "Get agent scoped to user. Returns nil on wrong owner or missing id."
  def get_agent(id, user_id) when is_binary(user_id) do
    case Repo.get_by(Agent, id: id, user_id: user_id) do
      nil -> nil
      agent -> Repo.preload(agent, :environment)
    end
  end

  @doc "Get agent scoped to user. Raises Ecto.NoResultsError if wrong owner."
  def get_agent!(id, user_id) when is_binary(user_id) do
    Repo.get_by!(Agent, id: id, user_id: user_id) |> Repo.preload(:environment)
  end

  @doc "List agents for user_id with optional keyword filters."
  def list_agents(user_id, filters) when is_binary(user_id) and is_list(filters) do
    from(a in Agent,
      where: a.user_id == ^user_id,
      order_by: [desc: a.inserted_at, desc: a.id],
      preload: [:environment]
    )
    |> apply_search(Keyword.get(filters, :search, ""))
    |> apply_runtimes(Keyword.get(filters, :runtimes, []))
    |> apply_env_ids(Keyword.get(filters, :env_ids, []))
    |> apply_has_skills(Keyword.get(filters, :has_skills, false))
    |> apply_has_mcp(Keyword.get(filters, :has_mcp, false))
    |> Repo.all()
  end

  @doc "List agents for user_id with total conversation counts. Accepts same filters as list_agents/2."
  def list_agents_with_counts(user_id, filters) when is_binary(user_id) and is_list(filters) do
    counts_subquery =
      from c in Conversation,
        where: c.user_id == ^user_id,
        group_by: c.agent_id,
        select: %{agent_id: c.agent_id, count: count(c.id)}

    from(a in Agent,
      where: a.user_id == ^user_id,
      order_by: [desc: a.inserted_at, desc: a.id],
      left_join: counts in subquery(counts_subquery),
      on: counts.agent_id == a.id,
      select_merge: %{conversation_count: fragment("COALESCE(?, 0)", counts.count)}
    )
    |> apply_search(Keyword.get(filters, :search, ""))
    |> apply_runtimes(Keyword.get(filters, :runtimes, []))
    |> apply_env_ids(Keyword.get(filters, :env_ids, []))
    |> apply_has_skills(Keyword.get(filters, :has_skills, false))
    |> apply_has_mcp(Keyword.get(filters, :has_mcp, false))
    |> Repo.all()
    # Preload done post-query (not inline in `from`) because select_merge is
    # incompatible with Ecto's inline preload compilation.
    |> Repo.preload(:environment)
  end

  def create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%Agent{} = agent), do: Repo.delete(agent)

  @doc "Upload or replace the avatar for an agent."
  def upload_avatar(%Agent{} = agent, data, media_type)
      when is_binary(data) and is_binary(media_type) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      Repo.insert!(
        %AgentAvatar{agent_id: agent.id, data: data, inserted_at: now},
        on_conflict: {:replace, [:data, :inserted_at]},
        conflict_target: :agent_id
      )

      agent
      |> Ecto.Changeset.change(%{avatar_media_type: media_type})
      |> Repo.update!()
    end)
  end

  @doc "Remove the avatar for an agent."
  def delete_avatar(%Agent{} = agent) do
    Repo.transaction(fn ->
      Repo.delete_all(from(av in AgentAvatar, where: av.agent_id == ^agent.id))

      agent
      |> Ecto.Changeset.change(%{avatar_media_type: nil})
      |> Repo.update!()
    end)
  end

  @doc "Fetch the raw avatar blob for an agent. Returns nil if none uploaded."
  def get_avatar(%Agent{id: agent_id}), do: Repo.get(AgentAvatar, agent_id)

  defp apply_search(query, ""), do: query

  defp apply_search(query, search) do
    term = "%#{search}%"
    from a in query, where: like(a.name, ^term)
  end

  defp apply_runtimes(query, []), do: query

  defp apply_runtimes(query, runtimes) do
    from a in query, where: a.runtime in ^runtimes
  end

  defp apply_env_ids(query, []), do: query

  defp apply_env_ids(query, env_ids) do
    {none, real_ids} = Enum.split_with(env_ids, &(&1 == "none"))

    cond do
      none != [] and real_ids != [] ->
        from a in query,
          where: is_nil(a.environment_id) or a.environment_id in ^real_ids

      none != [] ->
        from a in query, where: is_nil(a.environment_id)

      true ->
        from a in query, where: a.environment_id in ^real_ids
    end
  end

  defp apply_has_skills(query, false), do: query

  defp apply_has_skills(query, true) do
    from a in query, where: fragment("cardinality(?)", a.skills) > 0
  end

  defp apply_has_mcp(query, false), do: query

  defp apply_has_mcp(query, true) do
    from a in query, where: fragment("? != '{}'", a.mcp_servers)
  end
end
