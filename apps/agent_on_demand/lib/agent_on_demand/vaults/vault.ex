defmodule AgentOnDemand.Vaults.Vault do
  use Ecto.Schema
  import Ecto.Changeset

  alias AgentOnDemand.Vaults.VaultSecret

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vaults" do
    field :name, :string
    field :description, :string, default: ""
    # user_id FK column added by phase-3-foundation migration.
    field :user_id, :binary_id
    has_many :secrets, VaultSecret
    timestamps(type: :utc_datetime)
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name, :description, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 200)
    # Name is unique per user, not globally.
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
  end
end
