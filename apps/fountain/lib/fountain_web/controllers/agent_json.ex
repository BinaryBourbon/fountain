defmodule FountainWeb.AgentJSON do
  @moduledoc false
  alias Fountain.Agents.Agent

  def index(%{agents: agents}), do: %{data: Enum.map(agents, &data/1)}
  def show(%{agent: agent}), do: %{data: data(agent)}

  def data(%Agent{} = a) do
    %{
      id: a.id,
      name: a.name,
      description: a.description,
      system: a.system,
      model: a.model,
      runtime: a.runtime,
      environment_id: a.environment_id,
      skills: a.skills,
      mcp_servers: a.mcp_servers,
      metadata: a.metadata,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end
end
