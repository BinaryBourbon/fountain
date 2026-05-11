defmodule Fountain.Agents do
  @moduledoc "Context for agent definitions."

  import Ecto.Query, only: [from: 2]

  alias Fountain.Agents.Agent
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
