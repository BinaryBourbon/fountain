defmodule Fountain.Repo.Migrations.AddPerLaunchEnvironment do
  @moduledoc """
  A conversation's environment becomes a per-launch choice that defaults to
  the agent's (#783): the conversation carries an optional override, a Buzz
  identity can name one for every conversation it opens, and the agent gets an
  allowlist mirroring `allowed_vault_ids` to scope who may override.

  All three are `nilify_all` on environment delete — losing the override falls
  back to the agent's environment; it never orphans a row.
  """
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:buzz_identities) do
      add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:agents) do
      add :allowed_environment_ids, {:array, :binary_id}, null: true
    end

    create index(:conversations, [:environment_id])
    create index(:buzz_identities, [:environment_id])
  end
end
