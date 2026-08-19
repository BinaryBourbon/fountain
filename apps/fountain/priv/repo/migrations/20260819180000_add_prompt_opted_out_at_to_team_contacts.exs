defmodule Fountain.Repo.Migrations.AddPromptOptedOutAtToTeamContacts do
  @moduledoc """
  SMS opt-out (A2P/10DLC): when the registered number texts STOP, the
  teammate stops receiving its texts as prompts until START, or until the
  number is changed (fresh consent). Nothing is released.
  """
  use Ecto.Migration

  def change do
    alter table(:team_contacts) do
      add :prompt_opted_out_at, :utc_datetime
    end
  end
end
