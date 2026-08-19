defmodule Fountain.Repo.Migrations.CreateTeamContacts do
  @moduledoc """
  A teammate's email address and phone number (flag `team_comms`): the
  AgentMail inbox and AgentPhone number Fountain provisioned for it, keyed by
  the same `(user_id, agent_id)` pair that names a teammate. One row per
  teammate; deleting the user or the agent drops the row (the upstream
  resources are released by the context before that where it can).
  """
  use Ecto.Migration

  def change do
    create table(:team_contacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :email_address, :string
      add :email_inbox_id, :string
      add :phone_number, :string
      add :phone_number_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_contacts, [:user_id, :agent_id])
    create index(:team_contacts, [:agent_id])
  end
end
