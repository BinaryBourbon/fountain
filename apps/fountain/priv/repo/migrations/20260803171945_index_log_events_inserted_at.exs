defmodule Fountain.Repo.Migrations.IndexLogEventsInsertedAt do
  use Ecto.Migration

  # The nightly RetentionPruner filters log_events — the largest table in the
  # database — on inserted_at, which had no index: every batch of its delete
  # loop re-ran a sequential scan, and a run that deletes nothing still
  # scanned the whole table to find zero rows. audit_events and usage_events
  # both already carry this index.
  #
  # Concurrent build so the write path (every byte of sandbox output) is not
  # blocked while it runs; that requires running outside a transaction and
  # without the migration lock, and makes the operation non-atomic — safe
  # here because an index creation that fails halfway leaves an INVALID
  # index to drop, not data loss.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:log_events, [:inserted_at], concurrently: true)
  end
end
