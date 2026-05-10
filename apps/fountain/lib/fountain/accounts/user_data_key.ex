defmodule Fountain.Accounts.UserDataKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_data_keys" do
    field :wrapped_key, :binary
    # "aes_256_gcm_wrap" at launch; "kms" reserved for the planned KMS migration sprint
    field :algorithm, :string, default: "aes_256_gcm_wrap"
    # nil at launch; populated after KMS migration
    field :kms_key_id, :string

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(udk, attrs) do
    udk
    |> cast(attrs, [:user_id, :wrapped_key, :algorithm, :kms_key_id])
    |> validate_required([:user_id, :wrapped_key, :algorithm])
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
