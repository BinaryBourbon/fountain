defmodule Fountain.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new API key record.
  Expects :name, :key_hash, :key_prefix, :user_id to be provided.
  The raw key is never stored — callers must compute key_hash and key_prefix before
  calling this changeset.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_hash, :key_prefix, :user_id])
    |> validate_required([:name, :key_hash, :key_prefix, :user_id])
    |> validate_length(:name, min: 1, max: 200)
    |> unique_constraint(:key_hash)
    |> foreign_key_constraint(:user_id)
  end
end
