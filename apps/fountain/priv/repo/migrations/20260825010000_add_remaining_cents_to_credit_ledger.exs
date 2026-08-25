defmodule Fountain.Repo.Migrations.AddRemainingCentsToCreditLedger do
  use Ecto.Migration

  # ADR 0030, batch 2: every row that puts money in is a lot, and
  # `remaining_cents` is how much of it is still unspent. Debits consume lots
  # in a fixed order (a named lot, then the earliest expiry, then purchased),
  # so an expiry or a clawback takes exactly what its own lot still holds
  # instead of inferring it from the balance. Nil on debit rows and on rows
  # written before this column; `Fountain.Credits.rebuild_lots/1` replays a
  # tenant's ledger to fill it.
  def change do
    alter table(:credit_ledger) do
      add :remaining_cents, :integer
      # Insertion order, for replaying a ledger: `inserted_at` is a second and
      # a grant and its burn can share one.
      add :seq, :bigserial
    end

    create index(:credit_ledger, [:user_id, :expires_at, :inserted_at],
             where: "remaining_cents > 0",
             name: :credit_ledger_open_lots_index
           )
  end
end
