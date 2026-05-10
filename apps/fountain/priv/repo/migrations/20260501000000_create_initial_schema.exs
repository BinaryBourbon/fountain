defmodule Fountain.Repo.Migrations.CreateInitialSchema do
  use Ecto.Migration

  def change do
    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :packages, :map, null: false, default: %{}
      add :env_vars, :map, null: false, default: %{}
      add :setup_script, :text, null: false, default: ""
      add :networking_type, :string, null: false, default: "unrestricted"
      add :networking_config, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:environments, [:name])

    create table(:secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :value_ciphertext, :binary, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:secrets, [:environment_id, :key])

    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :system, :text, null: false, default: ""
      add :model, :string, null: false
      add :runtime, :string, null: false
      add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
      add :skills, {:array, :string}, null: false, default: []
      add :mcp_servers, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agents, [:name])

    create table(:sandboxes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
      add :sprite_name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :exit_code, :integer
      add :terminated_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:sandboxes, [:status])

    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sandbox_id, references(:sandboxes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :runtime, :string, null: false
      add :status, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:sandbox_id])
    create index(:conversations, [:status])

    create table(:turns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :turn_number, :integer, null: false
      add :prompt, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :exit_code, :integer
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:turns, [:conversation_id, :turn_number])

    # log_events use an integer PK so SSE Last-Event-ID resume is cheap.
    create table(:log_events) do
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :turn_id, references(:turns, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :stream, :string, null: false, default: ""
      add :data, :text, null: false, default: ""
      add :stage, :string, null: false, default: ""
      add :state, :string, null: false, default: ""
      add :duration_ms, :integer
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:log_events, [:conversation_id, :id])
    create index(:log_events, [:turn_id, :id])
  end
end
