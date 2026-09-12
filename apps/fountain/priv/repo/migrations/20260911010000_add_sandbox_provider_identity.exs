defmodule Fountain.Repo.Migrations.AddSandboxProviderIdentity do
  use Ecto.Migration

  def up do
    alter table(:sandboxes) do
      add :provider_instance_id, :text
    end

    # Retired rows retain the identity of their provider instance too.
    create unique_index(:sandboxes, [:provider, :provider_instance_id],
             where: "provider_instance_id IS NOT NULL"
           )
  end

  def down do
    execute "LOCK TABLE sandboxes IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM sandboxes WHERE provider_instance_id IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot discard recorded sandbox provider identities';
      END IF;
    END $$;
    """

    drop index(:sandboxes, [:provider, :provider_instance_id])

    alter table(:sandboxes) do
      remove :provider_instance_id
    end
  end
end
