defmodule Fountain.Repo.Migrations.CreateExecutionAllowances do
  use Ecto.Migration

  def up do
    create table(:execution_allowances, primary_key: false) do
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :limits, :map, null: false, default: %{}
      add :revision, :binary_id, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    # Lock before checking, so a concurrent insert cannot lose an allowance.
    execute "LOCK TABLE execution_allowances IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM execution_allowances) THEN
        RAISE EXCEPTION 'cannot discard saved execution allowances';
      END IF;
    END $$;
    """

    drop table(:execution_allowances)
  end
end
