defmodule Fountain.Repo.Migrations.AddConfigurationGenerationToSandboxes do
  use Ecto.Migration

  # A reapply keeps one conversation's transcript but gives it a freshly
  # materialized machine. The generation is an internal fifth leg of a
  # persistent home's identity: ordinary launches stay on the canonical nil
  # generation, while a reapplied conversation gets a private generation and
  # therefore cannot reset or silently reuse its cotenants' home.
  def up do
    drop index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id],
           name: :sandboxes_home_identity_index
         )

    alter table(:sandboxes) do
      add :configuration_generation, :binary_id
    end

    alter table(:conversations) do
      add :configuration_generation, :binary_id
    end

    create unique_index(
             :sandboxes,
             [:user_id, :agent_id, :environment_id, :vault_id, :configuration_generation],
             name: :sandboxes_home_identity_index,
             where: "mode = 'persistent' AND status NOT IN ('terminated', 'failed')",
             nulls_distinct: false
           )
  end

  def down do
    drop index(
           :sandboxes,
           [:user_id, :agent_id, :environment_id, :vault_id, :configuration_generation],
           name: :sandboxes_home_identity_index
         )

    alter table(:conversations) do
      remove :configuration_generation
    end

    alter table(:sandboxes) do
      remove :configuration_generation
    end

    create unique_index(:sandboxes, [:user_id, :agent_id, :environment_id, :vault_id],
             name: :sandboxes_home_identity_index,
             where: "mode = 'persistent' AND status NOT IN ('terminated', 'failed')",
             nulls_distinct: false
           )
  end
end
