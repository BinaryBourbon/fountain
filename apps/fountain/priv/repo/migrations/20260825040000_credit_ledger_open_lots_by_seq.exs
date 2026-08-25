defmodule Fountain.Repo.Migrations.CreditLedgerOpenLotsBySeq do
  use Ecto.Migration

  # The open-lots index ordered by `inserted_at`, but `Fountain.Credits`
  # consumes and lists lots by `expires_at, seq`: `inserted_at` is a second
  # and a grant and its burn can share one. Match the index to the reads.
  def change do
    drop index(:credit_ledger, [:user_id, :expires_at, :inserted_at],
           where: "remaining_cents > 0",
           name: :credit_ledger_open_lots_index
         )

    create index(:credit_ledger, [:user_id, :expires_at, :seq],
             where: "remaining_cents > 0",
             name: :credit_ledger_open_lots_index
           )
  end
end
