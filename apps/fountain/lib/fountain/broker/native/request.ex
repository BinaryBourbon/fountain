defmodule Fountain.Broker.Native.Request do
  @moduledoc """
  One row of the native broker's egress request log: a single request a
  brokered sandbox sent through the proxy, and what the proxy did about it.

  Written by `Fountain.Broker.Native.RequestLog` from the proxy's telemetry,
  read by `Fountain.Broker.Native.request_log/2` behind
  `GET /api/conversations/:id/egress`, swept by
  `Fountain.Workers.BrokerVaultReaper` on `BROKER_LOG_RETENTION_HOURS`.

  It holds no header, no body and no credential. `credential_keys` is the
  *names* of the environment variables whose values the proxy attached, which
  is the same thing the audit trail records for a secret event.

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
