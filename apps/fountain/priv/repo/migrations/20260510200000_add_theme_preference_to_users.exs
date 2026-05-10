defmodule Fountain.Repo.Migrations.AddThemePreferenceToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme_preference, :string, default: "system", null: false
    end
  end
end
