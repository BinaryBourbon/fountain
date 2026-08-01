defmodule Fountain.Repo.Migrations.AddScopesAndExpiryToApiKeys do
  use Ecto.Migration

  # Every key was previously unrestricted, including the per-conversation token
  # handed to each sprite — which meant code running in a sandbox could mint
  # itself a second, permanent key that outlived the conversation.
  #
  # Existing rows backfill to ["full"] so behaviour is unchanged on deploy;
  # only newly issued sprite tokens get the narrower scope.
  def up do
    alter table(:api_keys) do
      add :scopes, {:array, :string}, null: false, default: ["full"]
      add :expires_at, :utc_datetime
    end

    # Auth looks up by hash and then filters on expiry.
    create index(:api_keys, [:expires_at])
  end

  def down do
    drop index(:api_keys, [:expires_at])

    alter table(:api_keys) do
      remove :scopes
      remove :expires_at
    end
  end
end
