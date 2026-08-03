defmodule Fountain.Repo.Migrations.UniqueIndexUsersStripeCustomerId do
  use Ecto.Migration

  # Two users sharing a stripe_customer_id would make the webhook lookup
  # (Repo.get_by) raise Ecto.MultipleResultsError, which the controller
  # rescues into :retry — every delivery for that customer 500s through
  # Stripe's three-day retry window and is then dropped. Nothing in the app
  # can currently create the duplicate, so this is a guard, not a repair;
  # if it ever fails to apply, two rows already share an id and must be
  # merged by hand first.
  def change do
    drop index(:users, [:stripe_customer_id])
    create unique_index(:users, [:stripe_customer_id])
  end
end
