defmodule Fountain.Repo.Migrations.RecordActorStartupOutcomes do
  use Ecto.Migration

  def up do
    create table(:actor_startups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :sandbox_id, :binary_id, null: false
      add :deadline_at, :utc_datetime_usec, null: false
      add :state, :text, null: false, default: "starting"
      add :settled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:actor_startups, [:sandbox_id])

    create constraint(:actor_startups, :actor_startups_state_check,
             check:
               "(state = 'starting' AND settled_at IS NULL) OR (state IN ('completed', 'returned', 'expired') AND settled_at IS NOT NULL)"
           )

    execute("""
    CREATE FUNCTION guard_actor_startup() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR
         NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
         NEW.sandbox_id IS DISTINCT FROM OLD.sandbox_id OR
         NEW.deadline_at IS DISTINCT FROM OLD.deadline_at OR
         (OLD.state != 'starting' AND (NEW.state IS DISTINCT FROM OLD.state OR
           NEW.settled_at IS DISTINCT FROM OLD.settled_at)) THEN
        RAISE EXCEPTION 'actor startup identity, deadline and outcome are immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER actor_startup_guard BEFORE UPDATE ON actor_startups FOR EACH ROW EXECUTE FUNCTION guard_actor_startup();"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM actor_startups) THEN
        RAISE EXCEPTION 'cannot downgrade while actor startup history exists';
      END IF;
    END $$;
    """)

    drop table(:actor_startups)
    execute("DROP FUNCTION guard_actor_startup();")
  end
end
