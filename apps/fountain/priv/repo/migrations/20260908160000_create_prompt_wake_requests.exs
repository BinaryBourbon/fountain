defmodule Fountain.Repo.Migrations.CreatePromptWakeRequests do
  use Ecto.Migration

  def change do
    create table(:prompt_wake_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :sandbox_id, :binary_id
      add :state, :text, null: false, default: "requested"
      add :started_at, :utc_datetime_usec
      add :returned_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:prompt_wake_requests, [:conversation_id])

    create constraint(:prompt_wake_requests, :prompt_wake_requests_state_check,
             check: """
             (state = 'requested' AND started_at IS NULL AND returned_at IS NULL) OR
             (state = 'started' AND started_at IS NOT NULL AND returned_at IS NULL) OR
             (state = 'returned' AND started_at IS NOT NULL AND returned_at IS NOT NULL)
             """
           )

    execute(
      """
      CREATE FUNCTION guard_prompt_wake_request() RETURNS trigger AS $$
      BEGIN
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.user_id IS DISTINCT FROM OLD.user_id OR
           NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR
           NEW.sandbox_id IS DISTINCT FROM OLD.sandbox_id OR
           (OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at) OR
           (OLD.returned_at IS NOT NULL AND NEW.returned_at IS DISTINCT FROM OLD.returned_at) OR
           (OLD.state = 'started' AND NEW.state NOT IN ('started', 'returned')) OR
           (OLD.state = 'returned' AND NEW.state != 'returned') THEN
          RAISE EXCEPTION 'prompt wake identity and invocation history are immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION guard_prompt_wake_request();"
    )

    execute(
      """
      CREATE TRIGGER prompt_wake_request_guard BEFORE UPDATE ON prompt_wake_requests
        FOR EACH ROW EXECUTE FUNCTION guard_prompt_wake_request();
      """,
      "DROP TRIGGER prompt_wake_request_guard ON prompt_wake_requests;"
    )
  end
end
