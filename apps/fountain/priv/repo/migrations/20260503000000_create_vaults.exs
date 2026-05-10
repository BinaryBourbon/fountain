defmodule Fountain.Repo.Migrations.CreateVaults do
  use Ecto.Migration

  def change do
    create table(:vaults, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create unique_index(:vaults, [:name])

    create table(:vault_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false

      add :key, :string, null: false
      add :value_ciphertext, :binary, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_secrets, [:vault_id, :key])

    alter table(:conversations) do
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
