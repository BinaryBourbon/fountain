defmodule Fountain.Repo.Migrations.CreateRunners do
  use Ecto.Migration

  def change do
    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :hostname, :string
      add :os, :string
      add :arch, :string
      add :version, :string
      add :root, :string
      add :connected_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:runners, [:user_id, :name])
  end
end
