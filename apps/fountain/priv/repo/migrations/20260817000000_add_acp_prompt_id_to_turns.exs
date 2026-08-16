defmodule Fountain.Repo.Migrations.AddAcpPromptIdToTurns do
  use Ecto.Migration

  # The JSON-RPC id of the `session/prompt` request in flight for an ACP turn.
  # Set the moment the peer writes the prompt; read by the reattach path after
  # a BEAM restart, which needs it to tell the prompt's answer apart from the
  # replayed handshake responses. NULL means the prompt was never sent (or the
  # turn predates this column) — the turn cannot be resumed and is orphaned.
  def change do
    alter table(:turns) do
      add :acp_prompt_id, :integer
    end
  end
end
