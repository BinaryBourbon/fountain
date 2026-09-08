defmodule Fountain.Repo.Migrations.CreateConversationActorClaims do
  use Ecto.Migration

  def change do
    create table(:conversation_actor_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :sandbox_id, :binary_id, null: false
      add :state, :text, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_actor_claims, [:conversation_id],
             where: "state = 'active'",
             name: :conversation_actor_claims_one_active_index
           )

    create constraint(:conversation_actor_claims, :conversation_actor_claims_state_check,
             check: "state IN ('active', 'stopped', 'superseded')"
           )

    execute(
      """
      CREATE FUNCTION guard_conversation_actor_claim() RETURNS trigger AS $$
      BEGIN
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.user_id IS DISTINCT FROM OLD.user_id OR
           NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
           NEW.sandbox_id IS DISTINCT FROM OLD.sandbox_id OR
           (OLD.state != 'active' AND NEW.state IS DISTINCT FROM OLD.state) THEN
          RAISE EXCEPTION 'conversation actor claim identity and terminal state are immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION guard_conversation_actor_claim();"
    )

    execute(
      """
      CREATE TRIGGER conversation_actor_claim_guard BEFORE UPDATE ON conversation_actor_claims
        FOR EACH ROW EXECUTE FUNCTION guard_conversation_actor_claim();
      """,
      "DROP TRIGGER conversation_actor_claim_guard ON conversation_actor_claims;"
    )
  end
end
