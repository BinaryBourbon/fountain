defmodule Fountain.Repo.Migrations.AddAgentVersionIdToConversations do
  use Ecto.Migration

  @moduledoc """
  A conversation records which agent version it launched under, the same way
  it already snapshots `runtime`: provenance, so "why did it behave
  differently yesterday" is answerable from the row. Nullable — rows that
  predate versioning have none, and losing the version (nilify on delete)
  must never take a conversation with it.
  """

  def change do
    alter table(:conversations) do
      add :agent_version_id,
          references(:agent_versions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:conversations, [:agent_version_id], where: "agent_version_id IS NOT NULL")
  end
end
