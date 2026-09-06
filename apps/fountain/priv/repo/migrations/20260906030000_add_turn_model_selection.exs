defmodule Fountain.Repo.Migrations.AddTurnModelSelection do
  use Ecto.Migration

  def change do
    alter table(:turns) do
      add :model_selection, :map
    end
  end
end
