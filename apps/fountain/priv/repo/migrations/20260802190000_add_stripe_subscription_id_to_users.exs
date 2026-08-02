defmodule Fountain.Repo.Migrations.AddStripeSubscriptionIdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # The account's Stripe subscription of record. Webhook sync is keyed by
      # this, not by customer: a customer can briefly carry two subscriptions
      # (mid-trial upgrade), and customer-keyed sync let either one write the
      # account's status (#309).
      add :stripe_subscription_id, :string
    end
  end
end
