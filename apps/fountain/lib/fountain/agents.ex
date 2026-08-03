defmodule Fountain.Agents do
  @moduledoc "Context for agent definitions."

  import Ecto.Query, only: [from: 2]

  alias Fountain.Agents.Agent
  alias Fountain.Agents.AgentAvatar
  alias Fountain.Conversations.Conversation
  alias Fountain.Environments
  alias Fountain.Repo

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

  @doc "Get agent by name scoped to user. Returns nil when missing."
  def get_agent_by_name(name, user_id) when is_binary(name) and is_binary(user_id) do
    Repo.get_by(Agent, name: name, user_id: user_id)
  end

  def create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> validate_environment_owner()
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> validate_environment_owner()
    |> Repo.update()
  end

  # An agent may only reference an environment owned by the same tenant —
  # the environment's secrets and checkpoints materialise inside the
  # agent's sprite. The error mirrors a nonexistent id so a foreign
  # environment UUID can't be confirmed by probing.
  defp validate_environment_owner(changeset) do
    env_id = Ecto.Changeset.get_change(changeset, :environment_id)
    user_id = Ecto.Changeset.get_field(changeset, :user_id)

    cond do
      is_nil(env_id) ->
        changeset

      is_binary(user_id) && Environments.get_environment(env_id, user_id) ->
        changeset

      true ->
        Ecto.Changeset.add_error(changeset, :environment_id, "does not exist")
    end
  end

  def delete_agent(%Agent{} = agent), do: Repo.delete(agent)

  @doc """
  Upload or replace the avatar for an agent.

  The media type is validated against `Fountain.Images.valid_media_types/0`:
  it is echoed back verbatim by the avatar endpoint, and LiveView's upload
  `accept:` list does not constrain it — `accepted?/2` passes an entry whose
  *filename extension* matches even when the declared MIME type does not, so
  a crafted client can declare `text/html` with a `.png` name.
  """
  def upload_avatar(%Agent{} = agent, data, media_type)
      when is_binary(data) and is_binary(media_type) do
    if Fountain.Images.valid_media_type?(media_type) do
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
    else
      {:error, :invalid_media_type}
    end
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
    # ilike, not like: a case-sensitive search box is a broken one, and this
    # backs both the agents list in the UI and the documented ?search= param.
    term = "%#{search}%"
    from a in query, where: ilike(a.name, ^term)
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
