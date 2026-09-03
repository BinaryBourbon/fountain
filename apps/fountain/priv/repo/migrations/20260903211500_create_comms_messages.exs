defmodule Fountain.Repo.Migrations.CreateCommsMessages do
  use Ecto.Migration

  @moduledoc """
  A durable row per teammate message, which is what the credit ledger prices
  from (#1143).

  Comms messages used to be priced from `usage_events`, whose writer
  (`Billing.record_usage/5`) rescues and logs by contract — a metering outage
  must never fail a conversation. That contract is right for a count on a
  dashboard and wrong for a row the ledger keys on: a dropped `comms_*` event
  was a message the customer was never charged for, and nothing reconciled it
  afterwards, because the seven-day look-back only re-reads rows that exist.
  """

  def change do
    create table(:comms_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Not `on_delete: :delete_all`. Deleting an account must not silently
      # erase what it owed; the ledger rows that priced these outlive the user
      # the same way (ADR 0013's deletion semantics).
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :contact_id, references(:team_contacts, type: :binary_id, on_delete: :nilify_all)
      add :agent_id, :binary_id

      add :channel, :string, null: false
      add :direction, :string, null: false

      # The provider's own id for the message, and the idempotency key. A
      # retried send that reaches the provider twice converges on one row
      # rather than billing twice.
      add :provider_message_id, :string, null: false

      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    # What makes a double-charge impossible. Scoped by user as well as
    # channel: provider message ids are only unique within a provider, and
    # two tenants on the same provider could in principle collide.
    create unique_index(:comms_messages, [:user_id, :channel, :provider_message_id],
             name: :comms_messages_provider_id_index
           )

    # The pricer sweeps by time, oldest first, within its look-back window.
    create index(:comms_messages, [:inserted_at])

    # `Fountain.Billing.Finance` reports per tenant per period.
    create index(:comms_messages, [:user_id, :inserted_at])
  end
end
