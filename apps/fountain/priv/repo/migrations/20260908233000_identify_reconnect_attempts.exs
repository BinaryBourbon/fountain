defmodule Fountain.Repo.Migrations.IdentifyReconnectAttempts do
  use Ecto.Migration

  def up do
    alter table(:actor_startups) do
      add :actor_claim_id, :binary_id
    end

    execute("UPDATE actor_startups SET actor_claim_id = id")

    alter table(:actor_startups) do
      modify :actor_claim_id, :binary_id, null: false
    end

    create index(:actor_startups, [:actor_claim_id])

    create unique_index(:actor_startups, [:actor_claim_id],
             name: :actor_startups_one_pending_attempt,
             where: "state = 'starting'"
           )

    execute("""
    CREATE FUNCTION guard_actor_startup_claim() RETURNS trigger AS $$
    BEGIN
      IF NEW.actor_claim_id IS DISTINCT FROM OLD.actor_claim_id THEN
        RAISE EXCEPTION 'actor startup claim is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER actor_startup_claim_guard BEFORE UPDATE ON actor_startups FOR EACH ROW EXECUTE FUNCTION guard_actor_startup_claim();"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM actor_startups WHERE id != actor_claim_id) THEN
        RAISE EXCEPTION 'cannot downgrade while repeated reconnect history exists';
      END IF;
    END $$;
    """)

    execute("DROP TRIGGER actor_startup_claim_guard ON actor_startups;")
    execute("DROP FUNCTION guard_actor_startup_claim();")
    drop index(:actor_startups, [:actor_claim_id], name: :actor_startups_one_pending_attempt)
    drop index(:actor_startups, [:actor_claim_id])

    alter table(:actor_startups) do
      remove :actor_claim_id
    end
  end
end
