defmodule Fountain.Repo.Migrations.AddAccountExecutionLimits do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :execution_limits, :map, null: false, default: %{}
    end

    create constraint(:users, :users_execution_limits_object,
             check: "jsonb_typeof(execution_limits) = 'object'"
           )
  end

  def down do
    # Fence writes before checking: rollback must not silently discard a ceiling.
    execute "LOCK TABLE users IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM users WHERE execution_limits <> '{}'::jsonb) THEN
        RAISE EXCEPTION 'cannot discard configured account execution ceilings';
      END IF;
    END $$;
    """

    drop constraint(:users, :users_execution_limits_object)

    alter table(:users) do
      remove :execution_limits
    end
  end
end
