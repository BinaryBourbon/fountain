defmodule Fountain.Repo.Migrations.IndexRunningTurnsByStartedAt do
  use Ecto.Migration

  # Supports AutonomousTurnReaper's oldest-first candidate query. A partial
  # index keeps the structure small because only currently running turns that
  # are not waiting on a person can be candidates.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:turns, [:started_at],
             name: :turns_running_started_at_index,
             where: "status = 'running' AND pending_permission IS NULL",
             concurrently: true
           )
  end
end
