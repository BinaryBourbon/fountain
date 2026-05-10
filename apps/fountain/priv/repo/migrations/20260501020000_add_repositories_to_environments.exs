defmodule Fountain.Repo.Migrations.AddRepositoriesToEnvironments do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :repositories, {:array, :map}, null: false, default: []
    end
  end
end
