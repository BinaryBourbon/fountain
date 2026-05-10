defmodule Fountain.Repo.Migrations.AddRuntimeSessionIdToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :runtime_session_id, :string
    end
  end
end
