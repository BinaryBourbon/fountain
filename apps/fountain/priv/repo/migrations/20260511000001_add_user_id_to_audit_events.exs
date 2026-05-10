defmodule Fountain.Repo.Migrations.AddUserIdToAuditEvents do
  use Ecto.Migration

  def change do
    # nilify_all — audit events outlive the user they're attributed to.
    # Existing rows (written before per-tenant audit scoping landed) get
    # NULL and are only visible to admins.
    alter table(:audit_events) do
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:audit_events, [:user_id, :inserted_at])
  end
end
