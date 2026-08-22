defmodule Fountain.Repo.Migrations.AddPendingPermissionToTurns do
  use Ecto.Migration

  # The permission request a turn is blocked on (#940).
  #
  # Persisted for the same reason `acp_prompt_id` is: the JSON-RPC id lives in
  # the peer and dies with it, so without this a request raised before a deploy
  # could not be answered after one — the answer endpoint would accept a
  # request_id no live peer recognises. `attempt_session_attach` already
  # orphans a turn for exactly this class of problem.
  #
  # Holds the id, the tool, and the options the agent offered, so a reattached
  # peer can refuse the request without having seen it arrive.
  def change do
    alter table(:turns) do
      add :pending_permission, :map
    end
  end
end
