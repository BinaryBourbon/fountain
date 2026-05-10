defmodule Fountain.Repo.Migrations.AddProvenanceToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :source, :string, null: false, default: "api"
      add :parent_conversation_id, :binary_id, null: true
    end

    create index(:conversations, [:parent_conversation_id])
  end
end
