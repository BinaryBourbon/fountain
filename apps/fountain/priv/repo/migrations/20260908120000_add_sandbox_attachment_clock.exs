defmodule Fountain.Repo.Migrations.AddSandboxAttachmentClock do
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      add :last_attached_at, :utc_datetime_usec
    end
  end
end
