defmodule Fountain.OAuth.AuthorizationCode do
  @moduledoc """
  A one-time authorization code (OAuth 2.0 authorization code grant with
  PKCE). Stored hashed; bound to the user who consented, the client and
  redirect URI it was issued for, and the PKCE challenge the token exchange
  must answer. Five minutes to live, single use (`used_at`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "oauth_authorization_codes" do
    field :code_hash, :string
    field :client_id, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(code, attrs) do
    code
    |> cast(attrs, [:code_hash, :client_id, :redirect_uri, :code_challenge, :expires_at, :user_id])
    |> validate_required([
      :code_hash,
      :client_id,
      :redirect_uri,
      :code_challenge,
      :expires_at,
      :user_id
    ])
    |> unique_constraint(:code_hash)
  end
end
