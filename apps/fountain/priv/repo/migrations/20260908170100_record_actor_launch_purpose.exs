defmodule Fountain.Repo.Migrations.RecordActorLaunchPurpose do
  use Ecto.Migration

  def up do
    alter table(:actor_launches) do
      add :kind, :text, null: false, default: "create"
    end

    execute("UPDATE actor_launches SET kind = 'replace' WHERE source_sandbox_id IS NOT NULL")

    create constraint(:actor_launches, :actor_launches_kind_check,
             check: "(kind = 'create' AND source_sandbox_id IS NULL) OR kind = 'replace'"
           )

    guard("NEW.kind IS DISTINCT FROM OLD.kind OR")
  end

  def down do
    guard("")
    drop constraint(:actor_launches, :actor_launches_kind_check)

    alter table(:actor_launches) do
      remove :kind
    end
  end

  defp guard(kind_check) do
    execute("""
    CREATE OR REPLACE FUNCTION guard_actor_launch() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR
         NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
         NEW.source_sandbox_id IS DISTINCT FROM OLD.source_sandbox_id OR
         #{kind_check}
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
  end
end
