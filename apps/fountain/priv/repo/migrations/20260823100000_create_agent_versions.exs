defmodule Fountain.Repo.Migrations.CreateAgentVersions do
  use Ecto.Migration

  @moduledoc """
  Agent config versioning: one immutable row per shape the agent has had.
  `Fountain.Agents` writes version 1 on create and a new version on every
  update that changes a config field, so "why did the agent behave
  differently yesterday" has an answer and a bad edit has a one-click way
  back.

  Versions are tenant data, not audit rows: `config` deliberately holds the
  full values (the audit trail still records only which fields moved). They
  share the agent's lifetime — cascade on agent delete, no retention window
  of their own, which is a stated decision, not an omission: a version older
  than every conversation that ran it is still the only record of what the
  config was.

  The backfill stamps version 1 for every existing agent from its live row,
  so the invariant "every agent has at least one version" holds from the
  first deploy and new conversations can always record the version they ran.
  """

  def up do
    create table(:agent_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :config, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:agent_versions, [:agent_id, :version])
    create index(:agent_versions, [:user_id])

    execute """
    INSERT INTO agent_versions (id, agent_id, user_id, version, config, inserted_at)
    SELECT gen_random_uuid(), a.id, a.user_id, 1,
           jsonb_build_object(
             'name', a.name,
             'description', a.description,
             'system', a.system,
             'model', a.model,
             'runtime', a.runtime,
             'sandbox_provider', a.sandbox_provider,
             'skills', to_jsonb(a.skills),
             'mcp_servers', a.mcp_servers,
             'metadata', a.metadata,
             'allowed_vault_ids', to_jsonb(a.allowed_vault_ids),
             'allowed_environment_ids', to_jsonb(a.allowed_environment_ids),
             'permission_policy', a.permission_policy,
             'environment_id', a.environment_id
           ),
           now()
    FROM agents a
    """
  end

  def down do
    drop table(:agent_versions)
  end
end
