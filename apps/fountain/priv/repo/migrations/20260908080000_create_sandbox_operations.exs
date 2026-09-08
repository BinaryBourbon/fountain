defmodule Fountain.Repo.Migrations.CreateSandboxOperations do
  use Ecto.Migration

  def change do
    # Provider intent survives deletion of tenant/transcript rows. These UUIDs
    # are historical ownership, deliberately not cascading foreign keys.
    create table(:sandbox_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sandbox_id, :binary_id, null: false
      add :conversation_id, :binary_id
      add :user_id, :binary_id, null: false
      add :provider, :text, null: false
      add :sandbox_name, :text, null: false
      add :provider_instance_id, :text
      add :creation_id, :binary_id
      add :action, :text, null: false
      add :state, :text, null: false
      add :holds_slot, :boolean, null: false, default: false
      add :sandbox_started_at, :utc_datetime
      add :submitted_at, :utc_datetime_usec
      add :confirmed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sandbox_operations, [:provider, :sandbox_name],
             name: :sandbox_operations_physical_name_index,
             where: "action = 'create'"
           )

    create unique_index(:sandbox_operations, [:sandbox_id],
             name: :sandbox_operations_creation_index,
             where: "action = 'create'"
           )

    create unique_index(:sandbox_operations, [:provider, :provider_instance_id],
             name: :sandbox_operations_provider_instance_index,
             where: "action = 'create' AND provider_instance_id IS NOT NULL"
           )

    create unique_index(:sandbox_operations, [:sandbox_id],
             name: :sandbox_operations_pending_index,
             where: "state IN ('submitted', 'uncertain')"
           )

    create index(:sandbox_operations, [:user_id], where: "holds_slot")
    create index(:sandbox_operations, [:creation_id])

    create constraint(:sandbox_operations, :sandbox_operations_action_check,
             check: "action IN ('create', 'destroy', 'park', 'resume')"
           )

    create constraint(:sandbox_operations, :sandbox_operations_state_check,
             check: "state IN ('submitted', 'uncertain', 'confirmed', 'refused')"
           )

    create constraint(:sandbox_operations, :sandbox_operations_slot_check,
             check: "NOT holds_slot OR action = 'create'"
           )

    create constraint(:sandbox_operations, :sandbox_operations_submission_check,
             check: "state != 'submitted' OR submitted_at IS NOT NULL"
           )
  end
end
