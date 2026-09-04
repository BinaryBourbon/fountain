defmodule Fountain.Broker.Native.Request do
  @moduledoc """
  One row of the native broker's egress request log: a single request a
  brokered sandbox sent through the proxy, and what the proxy did about it.

  Written by `Fountain.Broker.Native.RequestLog` from the proxy's telemetry,
  read by `Fountain.Broker.Native.request_log/2` behind
  `GET /api/conversations/:id/egress`, swept by
  `Fountain.Workers.BrokerReaper` on `BROKER_LOG_RETENTION_HOURS`.

  It holds no header, no body and no credential. `credential_keys` is the
  *names* of the environment variables whose values the proxy attached, which
  is the same thing the audit trail records for a secret event.

  `path` is the URL path alone. A query string is dropped by the library
  before the event is emitted (`managoat_broker` 0.1.3, row 0 of #1501) and
  never reaches this column: a query can hold a credential the proxy never
  brokered, a signed URL being one in itself, so the "never record values"
  rule of `decisions/0013-audit-trail.md` would be broken here by a column
  nobody thinks of as sensitive. `broker_native_test.exs` pins it against
  the real proxy rather than against the library's changelog.

  `status`, `latency_ms` and `error` are nullable and unwritten: the proxy
  relays raw bytes and does not frame responses. They exist so this backend
  returns the same shape as the Agent Vault one.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @foreign_key_type :binary_id
  schema "broker_requests" do
    field :conversation_id, :binary_id
    field :user_id, :binary_id
    field :method, :string
    field :host, :string
    field :path, :string
    field :outcome, :string
    field :service, :string
    field :credential_keys, {:array, :string}, default: []
    field :status, :integer
    field :latency_ms, :integer
    field :error, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
