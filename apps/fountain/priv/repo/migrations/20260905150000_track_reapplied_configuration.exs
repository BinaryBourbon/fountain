defmodule Fountain.Repo.Migrations.TrackReappliedConfiguration do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :configuration_revision, :bigint, null: false, default: 0
    end

    alter table(:sandboxes) do
      add :applied_skills, {:array, :map}
    end
  end
end
