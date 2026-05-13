defmodule Fountain.Repo.Migrations.AddViewModePreferenceToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :conversation_view_mode, :string, null: false, default: "pretty"
    end
  end
end
