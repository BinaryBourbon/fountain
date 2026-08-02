defmodule Fountain.Repo.Migrations.CreateAccountExports do
  use Ecto.Migration

  def change do
    create table(:account_exports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      # Gzipped JSON document. Populated when status becomes "completed".
      add :payload, :binary
      # Size of the raw (uncompressed) JSON, for display.
      add :byte_size, :bigint
      add :error, :string
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:account_exports, [:user_id, :inserted_at])
    create index(:account_exports, [:expires_at])
  end
end
