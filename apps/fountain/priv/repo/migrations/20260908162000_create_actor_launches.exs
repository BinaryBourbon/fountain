defmodule Fountain.Repo.Migrations.CreateActorLaunches do
  use Ecto.Migration

  def up do
    create table(:actor_launches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :sandbox_id, :binary_id, null: false
      add :runtime, :text, null: false
      add :opening_receipt_id, :binary_id
      add :deadline_at, :utc_datetime_usec, null: false
      add :state, :text, null: false, default: "requested"
      add :actor_claim_id, :binary_id
      add :acknowledged_at, :utc_datetime_usec
      add :refused_at, :utc_datetime_usec
      add :failure_reason, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:actor_launches, [:sandbox_id])

    create index(:actor_launches, [:id],
             where: "state = 'requested'",
             name: :actor_launches_requested_index
           )

    create constraint(:actor_launches, :actor_launches_state_check,
             check: """
             (state = 'requested' AND actor_claim_id IS NULL AND acknowledged_at IS NULL AND refused_at IS NULL AND failure_reason IS NULL) OR
             (state = 'acknowledged' AND actor_claim_id IS NOT NULL AND acknowledged_at IS NOT NULL AND refused_at IS NULL AND failure_reason IS NULL) OR
             (state = 'refused' AND actor_claim_id IS NULL AND acknowledged_at IS NULL AND refused_at IS NOT NULL AND failure_reason IS NOT NULL)
             """
           )

    alter table(:conversation_actor_claims) do
      add :launch_id, :binary_id
    end

    create index(:conversation_actor_claims, [:launch_id])
    execute(claim_guard("NEW.launch_id IS DISTINCT FROM OLD.launch_id OR"))

    execute("""
    CREATE FUNCTION guard_actor_launch() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR
         NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
         NEW.sandbox_id IS DISTINCT FROM OLD.sandbox_id OR NEW.runtime IS DISTINCT FROM OLD.runtime OR
         NEW.opening_receipt_id IS DISTINCT FROM OLD.opening_receipt_id OR
         NEW.deadline_at IS DISTINCT FROM OLD.deadline_at OR
         (OLD.state != 'requested' AND (NEW.state IS DISTINCT FROM OLD.state OR
           NEW.actor_claim_id IS DISTINCT FROM OLD.actor_claim_id OR
           NEW.acknowledged_at IS DISTINCT FROM OLD.acknowledged_at OR
           NEW.refused_at IS DISTINCT FROM OLD.refused_at OR
           NEW.failure_reason IS DISTINCT FROM OLD.failure_reason)) THEN
        RAISE EXCEPTION 'actor launch identity, deadline and outcome are immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER actor_launch_guard BEFORE UPDATE ON actor_launches
      FOR EACH ROW EXECUTE FUNCTION guard_actor_launch();
    """)
  end

  def down do
    execute(claim_guard(""))
    drop index(:conversation_actor_claims, [:launch_id])

    alter table(:conversation_actor_claims) do
      remove :launch_id
    end

    drop table(:actor_launches)
    execute("DROP FUNCTION guard_actor_launch();")
  end

  defp claim_guard(launch_check) do
    """
    CREATE OR REPLACE FUNCTION guard_conversation_actor_claim() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR
         NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
         NEW.sandbox_id IS DISTINCT FROM OLD.sandbox_id OR #{launch_check}
         (OLD.state != 'active' AND NEW.state IS DISTINCT FROM OLD.state) THEN
        RAISE EXCEPTION 'conversation actor claim identity and terminal state are immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
