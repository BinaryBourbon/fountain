defmodule Fountain.Repo.Migrations.AddDeadlineEventIdentity do
  use Ecto.Migration

  def change do
    alter table(:turn_executions) do
      # Retain the identity after transcript retention/deletion. A missing event
      # must not permit a late actor to publish a contradictory replacement.
      add :deadline_event_id, :bigint
    end
  end
end
