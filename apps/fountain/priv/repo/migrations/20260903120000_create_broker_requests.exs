defmodule Fountain.Repo.Migrations.CreateBrokerRequests do
  use Ecto.Migration

  # ADR 0019 gate 4 on the native backend (#1486, #1359 row 2). What left a
  # brokered sandbox: one row per proxied request, written from the
  # `[:managoat, :broker, :request]` telemetry the proxy emits, read by
  # `GET /api/conversations/:id/egress`, swept by the reaper on
  # `BROKER_LOG_RETENTION_HOURS`. Never a header, never a body, never a
  # credential — `credential_keys` holds the *names* of the env vars whose
  # values the proxy attached, which is what the audit rules allow.
  #
  # A bigserial id, not a uuid: the endpoint's cursor is an integer and
  # "newest first, before this id" is the whole query.
  #
  # `status`, `latency_ms` and `error` are nullable and unwritten today. The
  # proxy is a raw byte pump and does not frame responses; the columns exist
  # so the API shape matches the Agent Vault backend row for row, and so
  # framing can fill them in without a migration.
  def change do
    create table(:broker_requests) do
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :method, :string, null: false
      add :host, :string, null: false
      add :path, :text, null: false
      add :outcome, :string, null: false
      add :service, :string
      add :credential_keys, {:array, :string}, null: false, default: []
      add :status, :integer
      add :latency_ms, :integer
      add :error, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The page is always "this conversation, newest first", and the reaper
    # sweeps by age. A chatty conversation writes a lot of rows, so these two
    # matter more here than on any other table we write.
    create index(:broker_requests, [:conversation_id, :id])
    create index(:broker_requests, [:inserted_at])
  end
end
