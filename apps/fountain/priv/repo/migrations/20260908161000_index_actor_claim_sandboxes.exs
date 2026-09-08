defmodule Fountain.Repo.Migrations.IndexActorClaimSandboxes do
  use Ecto.Migration

  def change do
    create index(:conversation_actor_claims, [:sandbox_id])
  end
end
