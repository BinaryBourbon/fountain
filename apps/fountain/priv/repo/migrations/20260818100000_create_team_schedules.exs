defmodule Fountain.Repo.Migrations.CreateTeamSchedules do
  @moduledoc """
  Scheduled prompts for teammates: a cron expression, a prompt, and whether
  it runs in the teammate's own conversation or on a one-off computer.

  Belongs to the user and the agent — deleting either takes the schedule
  with it. `last_conversation_id` is a pointer to the last run's
  conversation and only nilifies on delete; the run history is the
  conversations themselves.
  """
  use Ecto.Migration

  def change do
    create table(:team_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string
      add :cron, :string, null: false
      add :prompt, :text, null: false
      add :one_off, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :next_run_at, :utc_datetime
      add :last_run_at, :utc_datetime
      add :last_error, :string

      add :last_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:team_schedules, [:user_id])
    create index(:team_schedules, [:agent_id])
    # The ticker's query: enabled rows whose next run has come.
    create index(:team_schedules, [:next_run_at], where: "enabled")
  end
end
