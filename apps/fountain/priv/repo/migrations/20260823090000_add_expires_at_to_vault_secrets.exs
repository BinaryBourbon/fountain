defmodule Fountain.Repo.Migrations.AddExpiresAtToVaultSecrets do
  use Ecto.Migration

  @moduledoc """
  Vault secrets are mostly tokens with a lifetime the issuer chose, and today
  they expire silently: the first sign is a conversation failing with a 401.
  `expires_at` lets the owner record that lifetime; `expiry_notified_at` is
  the sweeper's bookkeeping so the advance-notice email sends once per expiry
  rather than daily.

  Both stay nullable: an expiry is optional metadata, and every existing row
  simply has none. The partial index carries the daily sweep, which only ever
  looks at rows that have an expiry and have not been notified.
  """

  def change do
    alter table(:vault_secrets) do
      add :expires_at, :utc_datetime
      add :expiry_notified_at, :utc_datetime
    end

    create index(:vault_secrets, [:expires_at],
             where: "expires_at IS NOT NULL AND expiry_notified_at IS NULL"
           )
  end
end
