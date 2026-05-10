defmodule Fountain.Repo.Migrations.CreateUserDataKeys do
  use Ecto.Migration

  def change do
    create table(:user_data_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :wrapped_key, :binary, null: false
      add :algorithm, :string, null: false, default: "aes_256_gcm_wrap"
      add :kms_key_id, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_data_keys, [:user_id])
  end
end
