defmodule Fountain.Repo.Migrations.IndexPlatformInferenceSpend do
  use Ecto.Migration

  # The deployment-wide daily ceiling reads this slice before every platform
  # inference turn. Tenant-leading indexes cannot serve that aggregate.
  # Build without blocking ledger writes, retaining the advisory migration lock.
  @disable_ddl_transaction true

  def change do
    create index(:credit_ledger, [:inserted_at],
             where: "reason = 'burn_inference'",
             name: :credit_ledger_inference_inserted_at_index,
             concurrently: true
           )
  end
end
