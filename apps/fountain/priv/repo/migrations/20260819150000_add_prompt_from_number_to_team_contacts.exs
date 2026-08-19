defmodule Fountain.Repo.Migrations.AddPromptFromNumberToTeamContacts do
  @moduledoc """
  The one phone number whose texts to a teammate's number arrive as prompts
  in the teammate's conversation (flag `team_comms`). Collected whenever a
  teammate is given a number; E.164. The index is what the inbound webhook
  resolves a delivery by: the teammate's own number.
  """
  use Ecto.Migration

  def change do
    alter table(:team_contacts) do
      add :prompt_from_number, :string
    end

    create index(:team_contacts, [:phone_number])
  end
end
