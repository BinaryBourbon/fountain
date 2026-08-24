defmodule Fountain.Repo.Migrations.CreateProviderInvoices do
  use Ecto.Migration

  # #1038 step 1: what a provider actually charged for a month, recorded by
  # hand from the invoice, so /admin/finance can hold it next to the computed
  # figure. One row per provider per month; recording again replaces it.
  def change do
    create table(:provider_invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :amount_cents, :integer, null: false
      add :note, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_invoices, [:provider, :period_start])
  end
end
