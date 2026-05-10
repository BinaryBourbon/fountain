defmodule Fountain.Repo.Migrations.CreateUsageEvents do
  use Ecto.Migration

  def change do
    create table(:usage_events) do
      # user_id intentionally has no on_delete — billing records survive user deletion
      add :user_id, references(:users, type: :binary_id), null: false
      add :event_type, :string, null: false
      add :resource_id, :binary_id
      add :resource_type, :string
      # jsonb on Postgres — stores metadata like runtime, model, region, duration_ms
      add :metadata, :map, null: false, default: %{}
      # write-once; no updated_at
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:usage_events, [:user_id])
    create index(:usage_events, [:event_type])
    create index(:usage_events, [:inserted_at])
  end
end
