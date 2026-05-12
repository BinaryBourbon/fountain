defmodule Fountain.Repo.Migrations.AddAgentAvatars do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :avatar_media_type, :string, null: true
    end

    create table(:agent_avatars, primary_key: false) do
      add :agent_id,
          references(:agents, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :data, :binary, null: false
      add :inserted_at, :utc_datetime, null: false
    end
  end
end
