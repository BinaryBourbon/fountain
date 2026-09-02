defmodule Fountain.Repo.Migrations.CreateBrokerSessions do
  use Ecto.Migration

  # ADR 0019 §8 as amended (#1340): the native egress broker's sessions. A
  # brokered conversation's proxy session, with the rules the proxy applies
  # and the credentials inside them, lives here so that any replica can
  # serve a sandbox's request. The rules are one ciphertext under the tenant
  # DEK, like the rows the values came from; the token is stored hashed.
  # Empty on a deployment that runs Agent Vault (BROKER_URL); written only
  # under BROKER_LISTEN_PORT.
  def change do
    create table(:broker_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :rules_ciphertext, :binary, null: false
      add :unmatched_host_policy, :string, null: false, default: "passthrough"
      add :meta, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:broker_sessions, [:token_hash])
    create index(:broker_sessions, [:conversation_id])
    create index(:broker_sessions, [:expires_at])
  end
end
