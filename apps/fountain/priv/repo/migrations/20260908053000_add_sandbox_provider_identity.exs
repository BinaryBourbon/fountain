defmodule Fountain.Repo.Migrations.AddSandboxProviderIdentity do
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      add :provider_instance_id, :text
    end

    # Shared conversations reuse one sandbox row. Two rows must not claim the
    # same provider instance, including a retired row kept as ownership history.
    create unique_index(:sandboxes, [:provider, :provider_instance_id],
             where: "provider_instance_id IS NOT NULL"
           )
  end
end
