defmodule Fountain.Repo.Migrations.CreateStripeEvents do
  use Ecto.Migration

  # Stripe retries a failed delivery for up to three days, and does not promise
  # ordering. Without a record of what has already been applied, a redelivered
  # `customer.subscription.updated{active}` arriving after `.deleted` silently
  # reactivates a cancelled account — and the reverse locks out a paying one.
  def change do
    create table(:stripe_events, primary_key: false) do
      # Stripe's own event id (evt_...) is the natural key; the unique index is
      # what makes claiming an event atomic under concurrent deliveries.
      add :id, :string, primary_key: true
      add :type, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    # Watermark for the ordering guard: the `created` timestamp of the most
    # recent subscription event actually applied to this user. Anything older
    # is stale and ignored.
    alter table(:users) do
      add :subscription_synced_at, :utc_datetime
    end
  end
end
