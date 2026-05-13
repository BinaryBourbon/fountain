defmodule Fountain.Repo.Migrations.AddTitleToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :title, :string, null: true
    end
  end
end
