defmodule Fountain.OAuth.DeviceGrant do
  @moduledoc """
  A device-authorization grant (RFC 8628 shape) for the CLI (#1305).

  Two codes, two audiences: the high-entropy `device_code` (stored hashed)
  stays on the machine that started the flow and is what the CLI polls with;
  the short `user_code` is what a human types into the console at `/device`.
  `user_id` is null until a signed-in user approves or denies. Single use
  (`used_at`), fifteen minutes to live.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "oauth_device_grants" do
    field :device_code_hash, :string
    field :user_code, :string
    field :approved_at, :utc_datetime
    field :denied_at, :utc_datetime
    field :used_at, :utc_datetime
    field :last_polled_at, :utc_datetime
    field :expires_at, :utc_datetime
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:device_code_hash, :user_code, :expires_at])
    |> validate_required([:device_code_hash, :user_code, :expires_at])
    |> unique_constraint(:device_code_hash)
    |> unique_constraint(:user_code)
  end
end
