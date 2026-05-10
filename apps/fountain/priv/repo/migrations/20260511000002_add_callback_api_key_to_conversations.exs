defmodule Fountain.Repo.Migrations.AddCallbackApiKeyToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :callback_api_key_id,
          references(:api_keys, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:conversations, [:callback_api_key_id])
  end
end
