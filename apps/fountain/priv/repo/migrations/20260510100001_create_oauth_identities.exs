defmodule Fountain.Repo.Migrations.CreateOauthIdentities do
  use Ecto.Migration

  def change do
    create table(:oauth_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_uid, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_identities, [:provider, :provider_uid])
    create index(:oauth_identities, [:user_id])
  end
end
