defmodule Fountain.Repo.Migrations.CreateTurnImages do
  use Ecto.Migration

  def change do
    create table(:turn_images, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :turn_id, references(:turns, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :media_type, :string, null: false
      add :data, :binary, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:turn_images, [:turn_id, :position])
  end
end
