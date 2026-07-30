defmodule Fountain.Repo.Migrations.AddAllowedVaultIdsToAgents do
  use Ecto.Migration

  # nil (default) preserves legacy behavior: any tenant vault may be attached
  # at conversation create. [] means no vault may be attached; a non-empty
  # list is an allowlist. Nullable on purpose — nil and [] mean different
  # things.
  def change do
    alter table(:agents) do
      add :allowed_vault_ids, {:array, :binary_id}, null: true
    end
  end
end
