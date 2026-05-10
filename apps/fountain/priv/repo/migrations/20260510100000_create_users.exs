defmodule Fountain.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string
      add :email_verified_at, :utc_datetime
      add :onboarding_completed_at, :utc_datetime
      add :max_concurrent_sandboxes, :integer, null: false, default: 5
      add :role, :string, null: false, default: "user"
      add :stripe_customer_id, :string
      add :subscription_status, :string, null: false, default: "trialing"
      add :trial_ends_at, :utc_datetime
      add :session_version, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:stripe_customer_id])
  end
end
