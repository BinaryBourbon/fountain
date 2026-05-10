defmodule Fountain.Repo.Migrations.AddCheckpointIdToEnvironments do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :checkpoint_id, :string
    end
  end
end
