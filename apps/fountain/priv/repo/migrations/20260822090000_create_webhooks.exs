defmodule Fountain.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhook_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :string, null: false, size: 2000
      add :description, :string
      # Encrypted, not hashed: we have to read it back to sign with it. Same
      # envelope path environment and vault secrets take (Fountain.Crypto).
      add :secret_ciphertext, :binary, null: false
      add :event_types, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "active"
      add :consecutive_failures, :integer, null: false, default: 0
      add :disabled_at, :utc_datetime
      add :disabled_reason, :string
      timestamps(type: :utc_datetime)
    end

    create index(:webhook_endpoints, [:user_id])
    # The dispatch read: active endpoints of one tenant, on every stage event.
    create index(:webhook_endpoints, [:user_id, :status])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :webhook_endpoint_id,
          references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all),
          null: false

      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :attempt, :integer, null: false, default: 1
      add :status_code, :integer
      add :duration_ms, :integer
      add :error, :string
      # Truncated at write time — see Fountain.Webhooks.Delivery.
      add :response_body, :text
      # The envelope that was POSTed. Carries no conversation content by
      # construction, and is what a manual redelivery replays.
      add :payload, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    # The "recent deliveries" read, and the retention sweep.
    create index(:webhook_deliveries, [:webhook_endpoint_id, :inserted_at])
    create index(:webhook_deliveries, [:inserted_at])
  end
end
