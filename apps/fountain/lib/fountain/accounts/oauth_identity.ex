defmodule Fountain.Accounts.OauthIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "oauth_identities" do
    field :provider, :string
    field :provider_uid, :string

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :provider, :provider_uid])
    |> validate_required([:user_id, :provider, :provider_uid])
    |> unique_constraint([:provider, :provider_uid])
    |> foreign_key_constraint(:user_id)
  end
end
