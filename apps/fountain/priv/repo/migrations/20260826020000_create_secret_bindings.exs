defmodule Fountain.Repo.Migrations.CreateSecretBindings do
  use Ecto.Migration

  # ADR 0019 gate 1b: which hosts a tenant's secret is attached to at the
  # egress broker, and how. Keyed by secret *name* per tenant, because
  # brokering runs on the merged environment ∪ vault map (§9) where only the
  # name survives, and because "my GITHUB_TOKEN goes to api.github.com as a
  # bearer" is true of every environment that holds one.
  def change do
    create table(:secret_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false
      # One box, as the broker itself takes it: host, `*.` wildcard, optional
      # `:port`, optional `/path/*` glob.
      add :host, :string, null: false
      add :auth_type, :string, null: false
      add :header, :string
      add :prefix, :string
      add :username, :string
      add :headers, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:secret_bindings, [:user_id, :key, :host])
    create index(:secret_bindings, [:user_id, :key])
  end
end
