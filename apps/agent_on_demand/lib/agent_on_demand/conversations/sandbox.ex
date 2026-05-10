defmodule AgentOnDemand.Conversations.Sandbox do
  use Ecto.Schema
  import Ecto.Changeset

  alias AgentOnDemand.Conversations.Conversation
  alias AgentOnDemand.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending starting ready terminated failed)

  schema "sandboxes" do
    field :sprite_name, :string
    field :status, :string, default: "pending"
    field :exit_code, :integer
    field :terminated_at, :utc_datetime
    # user_id FK column added by phase-3-foundation migration (nilify_all on delete).
    field :user_id, :binary_id
    belongs_to :environment, Environment
    has_many :conversations, Conversation
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, [:sprite_name, :status, :exit_code, :terminated_at, :environment_id, :user_id])
    |> validate_required([:sprite_name, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
