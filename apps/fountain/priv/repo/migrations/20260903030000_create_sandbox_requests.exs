defmodule Fountain.Repo.Migrations.CreateSandboxRequests do
  use Ecto.Migration

  def change do
    create table(:sandbox_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "start"
      add :attrs, :map, null: false, default: %{}
      add :schedule_id, :binary_id
      add :source, :string
      add :status, :string, null: false, default: "queued"

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:sandbox_requests, [:user_id, :status, :inserted_at])
    create index(:sandbox_requests, [:status], where: "status IN ('queued', 'starting')")
  end
end
