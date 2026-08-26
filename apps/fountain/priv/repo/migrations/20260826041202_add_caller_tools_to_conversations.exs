defmodule Fountain.Repo.Migrations.AddCallerToolsToConversations do
  use Ecto.Migration

  # #1202: the tools a chat-completions or AG-UI client defined on its
  # request, which the sandbox lists through `POST /api/mcp/caller/:id` and
  # which come back to the client as `tool_calls` when the agent uses one.
  # A list of `{name, description, parameters}`; last write wins.
  def change do
    alter table(:conversations) do
      add :caller_tools, {:array, :map}, null: false, default: []
    end
  end
end
