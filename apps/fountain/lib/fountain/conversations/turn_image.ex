defmodule Fountain.Conversations.TurnImage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.Turn

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @doc """
  Media types this endpoint is willing to store or serve.

  Read at serve time as well as in `changeset/2`: rows reach this table via
  `Conversations._unsafe_insert_turn_images/2`, which uses `Repo.insert_all` against a
  raw table name and therefore never runs the changeset. The list itself
  lives in `Fountain.Images` so the avatar path validates the same one.
  """
  def valid_media_types, do: Fountain.Images.valid_media_types()

  schema "turn_images" do
    field :position, :integer
    field :media_type, :string
    field :data, :binary
    field :inserted_at, :utc_datetime
    belongs_to :turn, Turn
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:position, :media_type, :data, :turn_id, :inserted_at])
    |> validate_required([:position, :media_type, :data, :turn_id])
    |> validate_inclusion(:media_type, Fountain.Images.valid_media_types())
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:turn_id, :position])
    # Without this a missing turn raises Ecto.ConstraintError instead of
    # returning a changeset, which would crash the ConversationServer — the
    # exact failure mode that kept validation out of this path.
    |> foreign_key_constraint(:turn_id)
  end
end
