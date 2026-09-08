defmodule Fountain.Repo.Migrations.CreatePlatformChatgptAccount do
  use Ecto.Migration

  # The deployment's ChatGPT grant for the codex runtime (ADR 0047). One row
  # with a NULL `user_id` is the platform's; the column exists so a
  # per-tenant "connect your ChatGPT" later is the same row with an owner,
  # not a second table. Both tokens are encrypted under the master key
  # (`Fountain.Crypto.encrypt_platform/1`); `id_claims` holds only the
  # non-secret claims codex reads back (account id, user id, plan type).
  #
  # `updated_by_user_id` is who connected it, for the admin page; nilified
  # rather than cascaded so deleting an operator's account does not
  # disconnect the deployment.
  def change do
    create table(:platform_chatgpt_account, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :refresh_token_ciphertext, :binary
      add :access_token_ciphertext, :binary, null: false
      add :id_claims, :map, null: false, default: %{}
      add :account_id, :string
      add :account_email, :string
      add :plan_type, :string
      add :access_expires_at, :utc_datetime
      add :last_refreshed_at, :utc_datetime
      add :status, :string, null: false, default: "active"
      add :revoked_reason, :string

      add :updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:platform_chatgpt_account, [:user_id], where: "user_id IS NOT NULL")

    create unique_index(:platform_chatgpt_account, ["(user_id IS NULL)"],
             where: "user_id IS NULL",
             name: :platform_chatgpt_account_platform_row
           )
  end
end
