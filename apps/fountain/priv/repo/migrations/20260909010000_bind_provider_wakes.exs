defmodule Fountain.Repo.Migrations.BindProviderWakes do
  use Ecto.Migration

  def up do
    alter table(:sandbox_operations) do
      add :wake_receipt_id, :binary_id
      add :wake_request_id, :binary_id
      add :wake_deadline_at, :utc_datetime_usec
    end

    drop constraint(:sandbox_operations, :sandbox_operations_slot_check)

    create constraint(:sandbox_operations, :sandbox_operations_slot_check,
             check:
               "NOT holds_slot OR action = 'create' OR (action = 'resume' AND creation_id IS NULL AND conversation_id IS NOT NULL AND wake_deadline_at IS NOT NULL)"
           )

    create constraint(:sandbox_operations, :sandbox_operations_wake_check,
             check:
               "(wake_deadline_at IS NULL AND wake_receipt_id IS NULL AND wake_request_id IS NULL) OR (action = 'resume' AND conversation_id IS NOT NULL AND wake_deadline_at IS NOT NULL AND (wake_request_id IS NULL OR (wake_receipt_id IS NOT NULL AND wake_request_id = wake_receipt_id)))"
           )

    execute("""
    CREATE FUNCTION guard_sandbox_wake() RETURNS trigger AS $$
    BEGIN
      IF NEW.wake_receipt_id IS DISTINCT FROM OLD.wake_receipt_id OR
         NEW.wake_request_id IS DISTINCT FROM OLD.wake_request_id OR
         NEW.wake_deadline_at IS DISTINCT FROM OLD.wake_deadline_at THEN
        RAISE EXCEPTION 'provider wake authority is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER sandbox_wake_guard BEFORE UPDATE ON sandbox_operations FOR EACH ROW EXECUTE FUNCTION guard_sandbox_wake();"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM sandbox_operations WHERE wake_deadline_at IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot downgrade while provider wake history exists';
      END IF;
    END $$;
    """)

    execute("DROP TRIGGER sandbox_wake_guard ON sandbox_operations;")
    execute("DROP FUNCTION guard_sandbox_wake();")
    drop constraint(:sandbox_operations, :sandbox_operations_wake_check)
    drop constraint(:sandbox_operations, :sandbox_operations_slot_check)

    create constraint(:sandbox_operations, :sandbox_operations_slot_check,
             check: "NOT holds_slot OR action = 'create'"
           )

    alter table(:sandbox_operations) do
      remove :wake_receipt_id
      remove :wake_request_id
      remove :wake_deadline_at
    end
  end
end
