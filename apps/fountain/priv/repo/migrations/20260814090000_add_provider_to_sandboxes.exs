defmodule Fountain.Repo.Migrations.AddProviderToSandboxes do
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      # Which sandbox backend owns this row. Every existing row is Sprites —
      # a non-volatile default on Postgres 11+ backfills as a metadata-only
      # change, and the default stays as belt-and-suspenders for raw inserts
      # during a rolling deploy.
      add :provider, :string, null: false, default: "sprites"

      # Adapter-opaque state (e.g. a server-assigned sandbox id where the
      # provider does not honor our minted name). Never exposed to tenants.
      add :provider_meta, :map, null: false, default: %{}
    end

    # The reaper's per-provider passes filter on exactly this pair.
    create index(:sandboxes, [:provider, :status])
  end
end
