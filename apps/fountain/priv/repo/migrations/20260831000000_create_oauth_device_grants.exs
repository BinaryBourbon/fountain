defmodule Fountain.Repo.Migrations.CreateOauthDeviceGrants do
  use Ecto.Migration

  def change do
    create table(:oauth_device_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_code_hash, :string, null: false
      add :user_code, :string, null: false
      # Null until a signed-in user approves or denies in the console.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :approved_at, :utc_datetime
      add :denied_at, :utc_datetime
      add :used_at, :utc_datetime
      add :last_polled_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_device_grants, [:device_code_hash])
    create unique_index(:oauth_device_grants, [:user_code])
    create index(:oauth_device_grants, [:expires_at])
  end
end
