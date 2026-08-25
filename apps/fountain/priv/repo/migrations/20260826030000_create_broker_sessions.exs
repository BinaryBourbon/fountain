defmodule Fountain.Repo.Migrations.CreateBrokerSessions do
  use Ecto.Migration

  # ADR 0019 §8 amended: the egress broker is Fountain's own. A brokered
  # conversation's proxy session, with the credentials the proxy attaches,
  # lives here so that any replica can serve a sandbox's request. The
  # credentials are ciphertext under the tenant DEK, like the rows they came
  # from; the token is stored hashed.
  def change do
    create table(:broker_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false
      add :vault, :string, null: false

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credentials_ciphertext, :binary, null: false
      add :services, :map, null: false, default: fragment("'[]'::jsonb")
      add :unmatched_host_policy, :string, null: false, default: "passthrough"
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:broker_sessions, [:token_hash])
    create index(:broker_sessions, [:conversation_id])
    create index(:broker_sessions, [:expires_at])
  end
end
