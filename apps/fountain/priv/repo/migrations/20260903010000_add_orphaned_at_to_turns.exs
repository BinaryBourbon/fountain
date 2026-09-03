defmodule Fountain.Repo.Migrations.AddOrphanedAtToTurns do
  use Ecto.Migration

  def change do
    alter table(:turns) do
      add :orphaned_at, :utc_datetime
    end
  end
end
