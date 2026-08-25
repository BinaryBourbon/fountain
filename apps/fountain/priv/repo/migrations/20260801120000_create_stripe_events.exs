defmodule Fountain.Repo.Migrations.CreateStripeEvents do
  use Ecto.Migration

  # Stripe retries a failed delivery for up to three days, and does not promise
  # ordering. Without a record of what has already been applied, a redelivered
  # event is applied twice. (Written for the subscription era; since ADR 0031
  # the events are credit purchases and clawbacks, and the claim is what makes
  # a redelivered purchase grant once. The `subscription_synced_at` column
  # below was dropped by 20260825060000.)
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
