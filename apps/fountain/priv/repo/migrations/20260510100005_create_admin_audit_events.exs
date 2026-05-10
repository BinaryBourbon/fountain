defmodule Fountain.Repo.Migrations.CreateAdminAuditEvents do
  use Ecto.Migration

  def change do
    create table(:admin_audit_events) do
      # nil for system events
      add :actor_user_id, :binary_id
      add :target_user_id, :binary_id
      add :event_type, :string, null: false
      # jsonb — resource ids, user agent, IP; never plaintext secrets
      add :metadata, :map, null: false, default: %{}
      # write-once; no updated_at
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:admin_audit_events, [:target_user_id])
    create index(:admin_audit_events, [:event_type])
    create index(:admin_audit_events, [:inserted_at])
  end
end
