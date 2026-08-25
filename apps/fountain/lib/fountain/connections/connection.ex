defmodule Fountain.Connections.Connection do
  @moduledoc """
  A provider account a tenant signed in to once, whose credential Fountain
  holds (#1178). The refresh token is encrypted with the tenant's DEK the way
  a vault secret is; the access token is a short-lived cache of the same
  shape, rewritten on every refresh. Neither ever enters a sandbox.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Crypto

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(google)
  @statuses ~w(active revoked)

  @type t :: %__MODULE__{}

  schema "connections" do
    field :provider, :string
    field :account_email, :string
    field :scopes, {:array, :string}, default: []
    field :env_key, :string
    field :refresh_token_ciphertext, :binary, redact: true
    field :access_token_ciphertext, :binary, redact: true
    field :refresh_token, :string, virtual: true, redact: true
    field :access_token, :string, virtual: true, redact: true
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"
    field :revoked_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def providers, do: @providers

  @doc """
  Create or replace a connection from a fresh token grant. `attrs` carries
  the plaintext `refresh_token` / `access_token`; both are encrypted with the
  tenant `dek` before they are persisted.
  """
  def changeset(conn, attrs, dek) when is_binary(dek) do
    conn
    |> cast(attrs, [
      :user_id,
      :provider,
      :account_email,
      :scopes,
      :env_key,
      :refresh_token,
      :access_token,
      :expires_at
    ])
    |> validate_required([:user_id, :provider, :account_email, :env_key, :refresh_token])
    |> validate_inclusion(:provider, @providers)
    |> validate_format(:env_key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be UPPER_SNAKE_CASE")
    |> validate_length(:account_email, min: 3, max: 320)
    |> put_change(:status, "active")
    |> put_change(:revoked_at, nil)
    |> encrypt(:refresh_token, :refresh_token_ciphertext, dek)
    |> encrypt(:access_token, :access_token_ciphertext, dek)
    |> unique_constraint([:user_id, :provider, :account_email])
    |> unique_constraint([:user_id, :env_key])
  end

  @doc "A refreshed access token, encrypted with the tenant `dek`."
  def refresh_changeset(conn, access_token, expires_at, dek) when is_binary(dek) do
    conn
    |> change(access_token: access_token, expires_at: expires_at)
    |> put_change(:last_refreshed_at, now())
    |> encrypt(:access_token, :access_token_ciphertext, dek)
  end

  @doc "The connection no longer works: the provider refused the refresh token, or the tenant revoked it."
  def revoke_changeset(conn) do
    conn
    |> change(status: "revoked", revoked_at: now())
    |> validate_inclusion(:status, @statuses)
  end

  defp encrypt(changeset, field, target, dek) do
    case get_change(changeset, field) do
      nil -> changeset
      value -> put_change(changeset, target, Crypto.encrypt(value, dek))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
