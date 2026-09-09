defmodule Fountain.Repo.Migrations.FenceSandboxResets do
  use Ecto.Migration

  def up do
    alter table(:sandboxes) do
      add :reset_requested_at, :utc_datetime_usec
    end
  end

  def down do
    # Keep a concurrent reset from adding evidence after the emptiness check.
    execute "LOCK TABLE sandboxes IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM sandboxes WHERE reset_requested_at IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot discard sandbox reset evidence';
      END IF;
    END $$;
    """

    alter table(:sandboxes) do
      remove :reset_requested_at
    end
  end
end
