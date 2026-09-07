defmodule Fountain.Repo.Migrations.IndexLogEventsOutputByConversation do
  use Ecto.Migration

  # Built concurrently: migrations run at boot while the previous replica is
  # still appending to log_events, and a plain CREATE INDEX would hold every
  # one of those writes for the duration.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  The conversation list's `last_active_at` is the newest `output` log event
  per conversation. It used to be computed as one aggregate over every
  output row in the table, joined back to the tenant's conversations, so
  every `GET /api/conversations` read all of log_events (6.4M sequential
  scans and 470 billion tuples read, on a 315 MB table, when this was
  found). The query now asks per conversation, and this partial index turns
  that question into one backward probe.
  """

  def change do
    create index(:log_events, [:conversation_id, :inserted_at],
             where: "kind = 'output'",
             name: :log_events_output_conversation_id_inserted_at_index,
             concurrently: true
           )
  end
end
