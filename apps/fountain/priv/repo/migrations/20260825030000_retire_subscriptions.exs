defmodule Fountain.Repo.Migrations.RetireSubscriptions do
  use Ecto.Migration

  # ADR 0031: credits are the product. `comped` replaces the one value of
  # subscription_status that still means something. The subscription columns
  # (plan, stripe_subscription_id, subscription_status, trial_ends_at,
  # subscription_synced_at, cancel_at_period_end, current_period_start/end)
  # stay in Postgres, unread, so the rolling deploy never selects a dropped
  # column; a later migration removes them.
  def up do
    alter table(:users) do
      add :comped, :boolean, null: false, default: false
    end

    execute "UPDATE users SET comped = true WHERE subscription_status = 'comped'"
  end

  def down do
    alter table(:users) do
      remove :comped
    end
  end
end
