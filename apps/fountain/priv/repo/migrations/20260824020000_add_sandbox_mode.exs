defmodule Fountain.Repo.Migrations.AddSandboxMode do
  use Ecto.Migration

  # ADR 0023 gate 6. A launch chooses a sandbox mode, defaulted from the
  # agent: `ephemeral` (a sandbox per conversation, today's model, the
  # default) or `persistent` (one sandbox per agent identity — the agent's
  # computer — that every conversation of that identity lands on). Both
  # columns default to `ephemeral`, so nothing changes for a row that
  # predates them.
  #
  # The partial unique index is what makes a home findable and single: one
  # live persistent sandbox per (user, agent, environment, vault). NULLS NOT
  # DISTINCT (Postgres 15+) so an agent with no vault and its own environment
  # still gets exactly one home rather than one per launch.
  def change do
    alter table(:agents) do
      add :sandbox_mode, :string, null: false, default: "ephemeral"
    end

    alter table(:sandboxes) do
      add :mode, :string, null: false, default: "ephemeral"
    end

    create unique_index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id],
             name: :sandboxes_home_identity_index,
             where: "mode = 'persistent' AND status NOT IN ('terminated', 'failed')",
             nulls_distinct: false
           )
  end
end
