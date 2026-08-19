defmodule Fountain.Repo.Migrations.AddPhoneAgentIdToTeamContacts do
  @moduledoc """
  AgentPhone only sends from a number that is attached to one of its
  "agents" (a persona record); Fountain creates one per teammate number and
  remembers it here so release can delete it again.
  """
  use Ecto.Migration

  def change do
    alter table(:team_contacts) do
      add :phone_agent_id, :string
    end
  end
end
