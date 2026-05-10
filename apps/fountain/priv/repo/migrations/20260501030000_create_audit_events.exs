defmodule Fountain.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :string
      add :actor, :string
      add :request_ip, :string
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:audit_events, [:resource_type, :resource_id])
    create index(:audit_events, [:inserted_at])
  end
end
