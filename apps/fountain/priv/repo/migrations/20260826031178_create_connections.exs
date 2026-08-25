defmodule Fountain.Repo.Migrations.CreateConnections do
  use Ecto.Migration

  # #1178: a tenant signs in to a provider once in the console and Fountain
  # holds the credential. The refresh token is DEK-encrypted like every other
  # tenant secret; the access token is a short-lived cache of the same shape.
  # Agents never see either — a Fountain-served MCP server uses the
  # connection server-side, and the egress broker attaches the access token
  # to requests for the provider's hosts (ADR 0019).
  def change do
    create table(:connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :account_email, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      # The env var name the access token is brokered under (`GOOGLE_ACCESS_TOKEN`).
      add :env_key, :string, null: false
      add :refresh_token_ciphertext, :binary, null: false
      add :access_token_ciphertext, :binary
      add :expires_at, :utc_datetime
      add :status, :string, null: false, default: "active"
      add :revoked_at, :utc_datetime
      add :last_refreshed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:connections, [:user_id, :provider, :account_email])
    create unique_index(:connections, [:user_id, :env_key])
    create index(:connections, [:user_id, :status])
  end
end
