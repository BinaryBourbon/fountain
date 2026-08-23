defmodule Fountain.Repo.Migrations.AddCurrentPeriodStartToUsers do
  use Ecto.Migration

  @moduledoc """
  `users.current_period_end` has been synced from Stripe since the cancellation
  notice needed it, but nothing recorded where the period *began*. Every
  surface that measured usage therefore measured a calendar month, which is
  fine for a display stat and wrong for an allowance: a customer who subscribed
  on the 20th gets a 10-day first "month" and every renewal boundary sits out
  of step with the invoice they are charged against.

  Nullable, and it stays nullable. A self-hosted deployment has no Stripe at
  all, a comped account has no invoiced period, and an account that has not
  received a subscription webhook since this shipped has none yet.
  `Fountain.Billing.billing_period/2` falls back to the calendar month for all
  three and says so rather than substituting silently.
  """

  def change do
    alter table(:users) do
      add :current_period_start, :utc_datetime
    end
  end
end
