defmodule Fountain.Repo.Migrations.ReserveLegacyProviderNames do
  use Ecto.Migration

  def up do
    drop index(:sandbox_operations, [:provider, :sandbox_name],
           name: :sandbox_operations_physical_name_index
         )

    create unique_index(:sandbox_operations, [:provider, :sandbox_name],
             name: :sandbox_operations_physical_name_index,
             where: "action = 'create' OR delete_deadline_at IS NOT NULL"
           )

    create unique_index(:sandbox_operations, [:provider, :sandbox_name],
             name: :sandbox_operations_pending_name_index,
             where: "state IN ('submitted', 'uncertain')"
           )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM sandbox_operations WHERE delete_deadline_at IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot discard retained legacy provider names';
      END IF;
    END $$;
    """)

    drop index(:sandbox_operations, [:provider, :sandbox_name],
           name: :sandbox_operations_pending_name_index
         )

    drop index(:sandbox_operations, [:provider, :sandbox_name],
           name: :sandbox_operations_physical_name_index
         )

    create unique_index(:sandbox_operations, [:provider, :sandbox_name],
             name: :sandbox_operations_physical_name_index,
             where: "action = 'create'"
           )
  end
end
