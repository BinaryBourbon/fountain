defmodule Fountain.Repo.Migrations.AddTurnExecutionGuards do
  use Ecto.Migration

  def change do
    alter table(:turns) do
      add :limit_reason, :text
    end

    # This is a provider-operation journal, not disposable transcript data.
    # Retain its immutable identifiers if a parent is removed: cascading an
    # uncertain termination would erase the fence needed to prevent replay.
    create table(:turn_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :turn_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :user_id, :binary_id, null: false
      add :sandbox_id, :binary_id, null: false
      add :sandbox_name, :text, null: false
      add :provider, :text, null: false
      add :connection_id, :binary_id, null: false
      add :provider_session_id, :text
      add :deadline_at, :utc_datetime_usec, null: false
      add :state, :text, null: false
      add :spawn_submitted_at, :utc_datetime_usec
      add :attempt_id, :binary_id
      add :submitted_at, :utc_datetime_usec
      add :confirmed_at, :utc_datetime_usec
      add :last_error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:turn_executions, [:turn_id])

    create unique_index(:turn_executions, [:conversation_id],
             name: :turn_executions_open_conversation_index,
             where: "state NOT IN ('completed', 'stopped')"
           )

    create index(:turn_executions, [:state, :deadline_at])
    create index(:turn_executions, [:connection_id])

    create index(:turn_executions, [:sandbox_id], where: "state NOT IN ('completed', 'stopped')")

    create constraint(:turn_executions, :turn_executions_state_check,
             check:
               "state IN ('active', 'awaiting_identity', 'ready', 'submitted', 'uncertain', 'stopped', 'completed')"
           )
  end
end
