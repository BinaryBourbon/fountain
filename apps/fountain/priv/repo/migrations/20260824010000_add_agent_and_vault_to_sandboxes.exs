defmodule Fountain.Repo.Migrations.AddAgentAndVaultToSandboxes do
  use Ecto.Migration

  # A sandbox is materialized from an agent's environment and a vault at
  # provision time, so a conversation may attach to it only with the same
  # three (ADR 0023). `environment_id` was already on the row; the agent and
  # the vault were only knowable through the conversations on it. Backfilled
  # from each sandbox's newest conversation — 1:1 in practice until now, so
  # "newest" and "only" agree.
  def up do
    alter table(:sandboxes) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sandboxes, [:user_id, :agent_id])

    execute """
    UPDATE sandboxes AS s
    SET agent_id = c.agent_id, vault_id = c.vault_id
    FROM (
      SELECT DISTINCT ON (sandbox_id) sandbox_id, agent_id, vault_id
      FROM conversations
      ORDER BY sandbox_id, inserted_at DESC
    ) AS c
    WHERE c.sandbox_id = s.id
    """
  end

  def down do
    drop index(:sandboxes, [:user_id, :agent_id])

    alter table(:sandboxes) do
      remove :agent_id
      remove :vault_id
    end
  end
end
