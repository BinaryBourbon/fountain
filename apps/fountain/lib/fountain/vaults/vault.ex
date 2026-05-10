defmodule Fountain.Vaults.Vault do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Vaults.VaultSecret

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vaults" do
    field :name, :string
    field :description, :string, default: ""
    has_many :secrets, VaultSecret
    timestamps(type: :utc_datetime)
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
    |> unique_constraint(:name)
  end
end
