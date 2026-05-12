defmodule Fountain.Agents.AgentAvatar do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Agents.Agent

  @primary_key {:agent_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "agent_avatars" do
    belongs_to :agent, Agent, define_field: false
    field :data, :binary
    field :inserted_at, :utc_datetime
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:agent_id, :data, :inserted_at])
    |> validate_required([:agent_id, :data, :inserted_at])
  end
end
