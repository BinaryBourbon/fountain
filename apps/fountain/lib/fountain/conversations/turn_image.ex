defmodule Fountain.Conversations.TurnImage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.Turn

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_media_types ~w(image/png image/jpeg image/gif image/webp)

  schema "turn_images" do
    field :position, :integer
    field :media_type, :string
    field :data, :binary
    field :inserted_at, :utc_datetime
    belongs_to :turn, Turn
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:position, :media_type, :data, :turn_id])
    |> validate_required([:position, :media_type, :data, :turn_id])
    |> validate_inclusion(:media_type, @valid_media_types)
    |> unique_constraint([:turn_id, :position])
  end
end
