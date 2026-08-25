defmodule Fountain.Repo.Migrations.DropSubscriptionColumnsFromUsers do
  use Ecto.Migration

  # ADR 0031 retired plans, trials and subscriptions (#1116) and removed the
  # Ecto fields; the columns stayed one release so a rolling deploy never
  # selected a column that was gone. Nothing reads them, no index names them.
  # `stripe_customer_id` stays: Checkout and the credit webhooks use it.
  def up do
    alter table(:users) do
      remove :plan
      remove :stripe_subscription_id
      remove :subscription_status
      remove :trial_ends_at
      remove :subscription_synced_at
      remove :cancel_at_period_end
      remove :current_period_start
      remove :current_period_end
    end
  end

  def down do
    alter table(:users) do
      add :plan, :string
      add :stripe_subscription_id, :string
      add :subscription_status, :string, null: false, default: "trialing"
      add :trial_ends_at, :utc_datetime
      add :subscription_synced_at, :utc_datetime
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
    end
  end
end
