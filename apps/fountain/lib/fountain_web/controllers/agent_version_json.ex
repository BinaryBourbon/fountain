defmodule FountainWeb.AgentVersionJSON do
  @moduledoc false
  alias Fountain.Agents.AgentVersion

  def index(%{versions: versions}), do: %{data: Enum.map(versions, &data/1)}
  def show(%{version: version}), do: %{data: data(version)}

  def data(%AgentVersion{} = v) do
    %{
      id: v.id,
      agent_id: v.agent_id,
      version: v.version,
      config: v.config,
      inserted_at: v.inserted_at
    }
  end
end
