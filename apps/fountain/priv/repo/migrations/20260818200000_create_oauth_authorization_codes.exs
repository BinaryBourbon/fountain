defmodule Fountain.Repo.Migrations.CreateOauthAuthorizationCodes do
  use Ecto.Migration

  def change do
    create table(:oauth_authorization_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code_hash, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])
    create index(:oauth_authorization_codes, [:expires_at])
  end
end
