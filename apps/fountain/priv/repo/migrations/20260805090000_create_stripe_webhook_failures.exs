defmodule Fountain.Repo.Migrations.CreateStripeWebhookFailures do
  use Ecto.Migration

  # A failed webhook leaves no DB trace: the stripe_events claim row rolls
  # back with the failed transaction, so failures exist only in Stripe's
  # dashboard and our logs — subscription state silently lags reality until
  # someone thinks to look (#501). One row per event id, upserted on each
  # retry, resolved when a later delivery of the same event succeeds.
  def change do
    create table(:stripe_webhook_failures, primary_key: false) do
      add :event_id, :string, primary_key: true
      add :event_type, :string, null: false
      add :error, :text, null: false
      add :failure_count, :integer, null: false, default: 1
      add :first_failed_at, :utc_datetime, null: false
      add :last_failed_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
    end

    create index(:stripe_webhook_failures, [:last_failed_at])
  end
end
