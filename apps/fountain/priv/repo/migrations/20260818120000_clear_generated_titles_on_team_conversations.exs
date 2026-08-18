defmodule Fountain.Repo.Migrations.ClearGeneratedTitlesOnTeamConversations do
  @moduledoc """
  A teammate's conversation title is the teammate's given name (#807) — but
  until now the first turn's auto-generated summary overwrote it, so the team
  page showed "Elixir Tic Tac Toe Game Development" where it should have
  shown the agent. Generation is now skipped for team-bound conversations;
  this clears what was already stamped. Every title on a team conversation at
  this point is a generated summary: naming a teammate shipped in the same
  hour, and no name was given through it before this migration.

  Not reversible in the sense of restoring the summaries — they were never
  wanted there.
  """
  use Ecto.Migration

  def up do
    execute("UPDATE conversations SET title = NULL WHERE channel_id = 'fountain:team'")
  end

  def down, do: :ok
end
