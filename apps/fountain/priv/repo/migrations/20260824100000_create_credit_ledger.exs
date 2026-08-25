defmodule Fountain.Repo.Migrations.CreateCreditLedger do
  use Ecto.Migration

  # ADR 0030 phase 2, step 1. The ledger is append-only and every row carries a
  # signed amount in cents; `users.credit_balance_cents` caches the sum so a
  # gate never sums the ledger. (Additive and inert when written; the pricer,
  # the grants and the gate landed over the following days.)
  def change do
    create table(:credit_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :reason, :string, null: false
      add :resource_type, :string
      add :resource_id, :string
      # One row per fact. A worker that prices the same turn twice, a webhook
      # Stripe delivers twice, an expiry sweep that restarts: all collapse
      # onto this key instead of onto the customer's balance.
      add :idempotency_key, :string, null: false
      # Set on a grant that stops being spendable at a point in time (the
      # monthly tier grant, the trial's opening grant). Nil on money the
      # customer paid for, which never expires.
      add :expires_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:credit_ledger, [:idempotency_key])
    create index(:credit_ledger, [:user_id, :inserted_at])
    create index(:credit_ledger, [:expires_at], where: "expires_at IS NOT NULL")

    alter table(:users) do
      add :credit_balance_cents, :integer, null: false, default: 0
    end
  end
end
