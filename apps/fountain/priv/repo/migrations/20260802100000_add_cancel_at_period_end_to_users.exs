defmodule Fountain.Repo.Migrations.AddCancelAtPeriodEndToUsers do
  use Ecto.Migration

  # A portal cancellation sets cancel_at_period_end on the Stripe subscription
  # while its status stays "active" until the period actually ends. Storing the
  # flag (and the period end) lets the billing page say "access until <date>"
  # instead of pretending nothing happened — without it, the first sign of the
  # cancellation the user sees is the hard lock when `.deleted` finally fires.
  def change do
    alter table(:users) do
      add :cancel_at_period_end, :boolean, default: false, null: false
      add :current_period_end, :utc_datetime
    end
  end
end
