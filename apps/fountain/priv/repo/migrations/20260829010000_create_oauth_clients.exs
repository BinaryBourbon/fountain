defmodule Fountain.Repo.Migrations.CreateOauthClients do
  use Ecto.Migration

  # #1125: OAuth clients a tenant registers for itself, so an app built inside
  # a sprite (or on localhost) can offer "Sign in with Fountain" against a
  # production server without an operator editing OAUTH_CLIENTS and
  # redeploying. ADR 0021's config registry stays and is treated as published.
  #
  # `published` is the security boundary, not the redirect allowlist: an
  # unpublished ("development mode") client may only ever authorize its own
  # owner, so its owner may register any redirect URI they like without that
  # becoming a way to capture somebody else's account.
  #
  # `origin_keys` is derived from redirect_uris by the changeset and exists so
  # the CORS plug can answer a preflight — which carries no auth — from the
  # origin alone with one indexed lookup. It holds the *lookup key* rather
  # than the origin verbatim: a loopback origin is stored without its port,
  # because a redirect to loopback matches on any port (RFC 8252) and a CORS
  # rule that did not would fail the moment Vite moved off 5173.
  def change do
    create table(:oauth_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :name, :string, null: false
      add :redirect_uris, {:array, :string}, null: false, default: []
      add :origin_keys, {:array, :string}, null: false, default: []
      add :published, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])
    create index(:oauth_clients, [:user_id])
    create index(:oauth_clients, [:origin_keys], using: :gin)
  end
end
