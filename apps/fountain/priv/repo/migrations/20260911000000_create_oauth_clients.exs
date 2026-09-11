defmodule Fountain.Repo.Migrations.CreateOauthClients do
  use Ecto.Migration

  # Tenant-owned OAuth clients (#1125). Operator-configured clients remain
  # published first-party apps; rows start unpublished and may authorize only
  # their owner.
  #
  # origin_keys is derived from redirect_uris. It lets the CORS plug answer an
  # unauthenticated preflight with an indexed lookup. Loopback keys omit the
  # port to match RFC 8252's any-port redirect behavior.
  def change do
    create table(:oauth_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :name, :string, null: false
      add :redirect_uris, {:array, :string}, null: false, default: []
      add :origin_keys, {:array, :string}, null: false, default: []
      add :published, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])
    create index(:oauth_clients, [:user_id])
    create index(:oauth_clients, [:origin_keys], using: :gin)
  end
end
