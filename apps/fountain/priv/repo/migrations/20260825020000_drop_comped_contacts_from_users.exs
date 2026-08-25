defmodule Fountain.Repo.Migrations.DropCompedContactsFromUsers do
  use Ecto.Migration

  # #1109 retired the Stripe teammate-contact add-on and removed the Ecto
  # field; the column stayed one release so a rolling deploy never selected
  # a column that was gone. Nothing has read it since, so it goes.
  def up do
    alter table(:users) do
      remove :comped_contacts
    end
  end

  def down do
    alter table(:users) do
      add :comped_contacts, :integer, null: false, default: 0
    end
  end
end
