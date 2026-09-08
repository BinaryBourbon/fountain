defmodule Fountain.Repo.Migrations.IndexPendingActorStartups do
  use Ecto.Migration

  def change do
    create index(:actor_startups, [:id],
             name: :actor_startups_pending_scan,
             where: "state = 'starting'"
           )
  end
end
