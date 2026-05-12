defmodule Fountain.Repo.Migrations.AddUserFilterPreferences do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :conversations_roots_only, :boolean, null: false, default: false
      add :conversation_visible_streams, {:array, :string}, null: false, default: ["stdout", "stderr", "stage"]
    end
  end
end
