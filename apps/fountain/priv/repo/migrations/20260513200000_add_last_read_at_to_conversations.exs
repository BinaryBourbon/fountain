defmodule Fountain.Repo.Migrations.AddLastReadAtToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :last_read_at, :utc_datetime_usec
    end
  end
end
