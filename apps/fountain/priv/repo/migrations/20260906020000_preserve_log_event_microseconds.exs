defmodule Fountain.Repo.Migrations.PreserveLogEventMicroseconds do
  use Ecto.Migration

  # LogEvent has long used :utc_datetime_usec, but the initial migration made
  # this timestamp(0). Live broadcasts use the inserted struct's microseconds;
  # history and replay read a rounded database value (#1624).
  #
  # Widen the existing column, retaining old rows as stored. Lost fractional
  # seconds cannot be recovered. ALTER TABLE still needs an exclusive lock on
  # this high-volume table: fail promptly under contention and retry the
  # migration once the blocker is gone, rather than queueing writes forever.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:log_events) do
      modify :inserted_at, :utc_datetime_usec
    end
  end

  # Older application code already expects microseconds and works with the
  # widened column. Roll back the application without narrowing the data.
  def down do
    raise Ecto.MigrationError,
      message: "Cannot narrow log_events.inserted_at without losing persisted microseconds"
  end
end
