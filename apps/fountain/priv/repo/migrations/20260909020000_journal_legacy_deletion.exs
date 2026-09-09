defmodule Fountain.Repo.Migrations.JournalLegacyDeletion do
  use Ecto.Migration

  def up do
    alter table(:sandbox_operations) do
      add :delete_deadline_at, :utc_datetime_usec
      add :delete_started_at, :utc_datetime_usec
    end

    drop constraint(:sandbox_operations, :sandbox_operations_slot_check)

    create constraint(:sandbox_operations, :sandbox_operations_slot_check,
             check:
               "NOT holds_slot OR action = 'create' OR (action = 'resume' AND creation_id IS NULL AND conversation_id IS NOT NULL AND wake_deadline_at IS NOT NULL) OR (action = 'destroy' AND creation_id IS NULL AND delete_deadline_at IS NOT NULL)"
           )

    create constraint(:sandbox_operations, :sandbox_operations_delete_deadline_check,
             check:
               "delete_deadline_at IS NULL OR (action = 'destroy' AND creation_id IS NULL AND submitted_at IS NOT NULL AND delete_deadline_at > submitted_at)"
           )

    create constraint(:sandbox_operations, :sandbox_operations_delete_started_check,
             check:
               "delete_started_at IS NULL OR (delete_deadline_at IS NOT NULL AND delete_started_at >= submitted_at AND delete_started_at < delete_deadline_at)"
           )

    create unique_index(:sandbox_operations, [:sandbox_id],
             name: :sandbox_operations_legacy_delete_index,
             where: "action = 'destroy' AND delete_deadline_at IS NOT NULL"
           )

    execute("""
    CREATE FUNCTION guard_legacy_delete_deadline() RETURNS trigger AS $$
    BEGIN
      IF NEW.delete_deadline_at IS DISTINCT FROM OLD.delete_deadline_at OR
         (OLD.delete_started_at IS NOT NULL AND NEW.delete_started_at IS DISTINCT FROM OLD.delete_started_at) THEN
        RAISE EXCEPTION 'legacy delete deadline is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER legacy_delete_deadline_guard BEFORE UPDATE ON sandbox_operations FOR EACH ROW EXECUTE FUNCTION guard_legacy_delete_deadline();"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM sandbox_operations WHERE delete_deadline_at IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot downgrade while legacy deletion history exists';
      END IF;
    END $$;
    """)

    execute("DROP TRIGGER legacy_delete_deadline_guard ON sandbox_operations;")
    execute("DROP FUNCTION guard_legacy_delete_deadline();")
    drop index(:sandbox_operations, [:sandbox_id], name: :sandbox_operations_legacy_delete_index)
    drop constraint(:sandbox_operations, :sandbox_operations_delete_deadline_check)
    drop constraint(:sandbox_operations, :sandbox_operations_delete_started_check)
    drop constraint(:sandbox_operations, :sandbox_operations_slot_check)

    create constraint(:sandbox_operations, :sandbox_operations_slot_check,
             check:
               "NOT holds_slot OR action = 'create' OR (action = 'resume' AND creation_id IS NULL AND conversation_id IS NOT NULL AND wake_deadline_at IS NOT NULL)"
           )

    alter table(:sandbox_operations) do
      remove :delete_deadline_at
      remove :delete_started_at
    end
  end
end
