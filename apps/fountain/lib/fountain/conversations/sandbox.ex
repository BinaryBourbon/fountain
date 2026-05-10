defmodule Fountain.Conversations.Sandbox do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.Conversation
  alias Fountain.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending starting ready terminated failed)

  schema "sandboxes" do
    field :sprite_name, :string
    field :status, :string, default: "pending"
    field :exit_code, :integer
    field :terminated_at, :utc_datetime
    belongs_to :environment, Environment
    has_many :conversations, Conversation
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, [:sprite_name, :status, :exit_code, :terminated_at, :environment_id])
    |> validate_required([:sprite_name, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
