defmodule Fountain.Repo.Migrations.AddMetadataToEnvironmentsAndVaults do
  use Ecto.Migration

  # Free-form caller bookkeeping, mirroring agents.metadata — gives external
  # tooling (reconcilers, IaC) a marker channel on all three manifest kinds.
  def change do
    alter table(:environments) do
      add :metadata, :map, default: %{}, null: false
    end

    alter table(:vaults) do
      add :metadata, :map, default: %{}, null: false
    end
  end
end
