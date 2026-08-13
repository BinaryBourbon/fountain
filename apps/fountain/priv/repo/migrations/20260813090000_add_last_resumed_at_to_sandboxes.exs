defmodule Fountain.Repo.Migrations.AddLastResumedAtToSandboxes do
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      add :last_resumed_at, :utc_datetime
    end
  end
end
