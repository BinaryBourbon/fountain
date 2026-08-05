defmodule Fountain.Vaults.Vault do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Vaults.VaultSecret

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vaults" do
    field :name, :string
    field :description, :string, default: ""
    field :metadata, :map, default: %{}

    # Populated by the *_with_counts reads — not persisted.
    field :secret_count, :integer, virtual: true, default: 0

    belongs_to :user, User
    has_many :secrets, VaultSecret
    timestamps(type: :utc_datetime)
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name, :description, :metadata, :user_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
    |> unique_constraint(:name, name: :vaults_user_id_name_index)
  end
end
