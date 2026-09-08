defmodule Fountain.Repo.Migrations.AllowActorReconnectRequests do
  use Ecto.Migration

  def up do
    alter table(:actor_launches) do
      add :reconnect_identity, :map
    end

    guard("NEW.reconnect_identity IS DISTINCT FROM OLD.reconnect_identity OR")
    drop index(:actor_launches, [:sandbox_id])

    create unique_index(:actor_launches, [:sandbox_id],
             where: "kind IN ('create', 'replace')",
             name: :actor_launches_creation_index
           )

    create unique_index(:actor_launches, [:conversation_id],
             where: "state = 'requested'",
             name: :actor_launches_pending_parent_index
           )

    drop constraint(:actor_launches, :actor_launches_kind_check)

    create constraint(:actor_launches, :actor_launches_kind_check,
             check:
               "((kind = 'create' AND source_sandbox_id IS NULL) OR kind = 'replace') AND reconnect_identity IS NULL OR (kind = 'reconnect' AND source_sandbox_id IS NULL AND reconnect_identity IS NOT NULL AND jsonb_typeof(reconnect_identity) = 'object')"
           )
  end

  def down do
    # Refuse rollback once reconnect history exists. Removing that history would
    # erase accepted startup identities and could authorize replay after downgrade.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM actor_launches WHERE kind = 'reconnect') THEN
        RAISE EXCEPTION 'cannot downgrade while actor reconnect history exists';
      END IF;
    END $$;
    """)

    drop constraint(:actor_launches, :actor_launches_kind_check)

    create constraint(:actor_launches, :actor_launches_kind_check,
             check: "(kind = 'create' AND source_sandbox_id IS NULL) OR kind = 'replace'"
           )

    drop index(:actor_launches, [:conversation_id], name: :actor_launches_pending_parent_index)
    drop index(:actor_launches, [:sandbox_id], name: :actor_launches_creation_index)
    create unique_index(:actor_launches, [:sandbox_id])
    guard("")

    alter table(:actor_launches) do
      remove :reconnect_identity
    end
  end

  defp guard(identity_check) do
    execute("""
    CREATE OR REPLACE FUNCTION guard_actor_launch() RETURNS trigger AS $$
    BEGIN
      IF NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR
         NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
         NEW.source_sandbox_id IS DISTINCT FROM OLD.source_sandbox_id OR
         NEW.kind IS DISTINCT FROM OLD.kind OR
         #{identity_check}
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
