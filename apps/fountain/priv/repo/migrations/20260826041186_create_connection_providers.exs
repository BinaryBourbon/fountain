defmodule Fountain.Repo.Migrations.CreateConnectionProviders do
  use Ecto.Migration

  # #1186: a tenant brings their own OAuth provider. A row is the tenant's
  # app registration at a service (`oauth2`) or a remote MCP server whose
  # authorization server Fountain discovered and, where it could, registered
  # a client with (`mcp`). The client secret is DEK-encrypted like a vault
  # secret. Google stays config-backed and has no row: `connections.provider_id`
  # is null for it.
  def change do
    create table(:connection_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :kind, :string, null: false
      add :authorize_url, :string
      add :token_url, :string
      add :revoke_url, :string
      add :userinfo_url, :string
      # A dotted JSON path into the userinfo body that names the account
      # (`email`, `data.login`). Null: the tenant is asked on connect.
      add :account_label_path, :string
      add :scopes, {:array, :string}, null: false, default: []
      add :client_id, :string
      add :client_secret_ciphertext, :binary
      add :token_endpoint_auth, :string, null: false, default: "client_secret_post"
      add :pkce, :boolean, null: false, default: true
      # The env var name the access token is brokered under; a second
      # account of the provider gets `_2`.
      add :env_key, :string, null: false
      # Where the implicit bearer binding goes.
      add :token_hosts, {:array, :string}, null: false, default: []
      # `mcp` only: the server URL, the authorization server that protects it
      # and what discovery found there (RFC 9728 + RFC 8414 metadata).
      add :mcp_url, :string
      add :issuer, :string
      add :mcp_metadata, :map, null: false, default: %{}
      # `dcr` when the client came from RFC 7591 registration, `manual` when
      # the tenant typed it.
      add :client_source, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:connection_providers, [:user_id, :slug])
    create unique_index(:connection_providers, [:user_id, :env_key])
    create index(:connection_providers, [:user_id, :issuer])

    alter table(:connections) do
      add :provider_id,
          references(:connection_providers, type: :binary_id, on_delete: :delete_all)

      # A provider that hands out no refresh token leaves this null, and the
      # connection goes `expired` when the access token does.
      modify :refresh_token_ciphertext, :binary, null: true
    end

    create index(:connections, [:provider_id])
  end
end
