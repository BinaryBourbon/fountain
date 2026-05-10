defmodule AgentOnDemand.Agents do
  @moduledoc "Context for agent definitions."

  import Ecto.Query, only: [from: 2]

  alias AgentOnDemand.Agents.Agent
  alias AgentOnDemand.Repo

  def list_agents(user_id, filters \\ []) do
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

  @doc "Returns the agent if it belongs to user_id, otherwise nil."
  def get_agent(id, user_id) do
    Repo.get_by(Agent, id: id, user_id: user_id)
    |> maybe_preload()
  end

  @doc """
  Returns the agent. Raises Ecto.NoResultsError if not found or
  the agent does not belong to user_id (cross-tenant access → 404).
  """
  def get_agent!(id, user_id) do
    Repo.get_by!(Agent, id: id, user_id: user_id)
    |> Repo.preload(:environment)
  end

  def create_agent(attrs, user_id) do
    %Agent{}
    |> Agent.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs, _user_id) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  # user_id accepted for call-site symmetry; ownership enforced by prior fetch.
  def delete_agent(%Agent{} = agent, _user_id), do: Repo.delete(agent)

  defp maybe_preload(nil), do: nil
  defp maybe_preload(agent), do: Repo.preload(agent, :environment)

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
    from a in query, where: fragment("jsonb_array_length(?::jsonb)", a.skills) > 0
  end

  defp apply_has_mcp(query, false), do: query

  defp apply_has_mcp(query, true) do
    from a in query, where: fragment("? != '{}'", a.mcp_servers)
  end
end
