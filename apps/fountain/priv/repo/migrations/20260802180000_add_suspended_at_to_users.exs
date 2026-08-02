defmodule Fountain.Repo.Migrations.AddSuspendedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # nil = not suspended; the timestamp doubles as the audit anchor for
      # "how long has this account been locked".
      add :suspended_at, :utc_datetime
    end
  end
end
