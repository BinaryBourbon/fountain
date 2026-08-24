defmodule Fountain.Repo.Migrations.AddRentToTeamContacts do
  use Ecto.Migration

  # ADR 0030 decision 4: a number and an inbox are rented a month up front.
  # `rent_paid_through` is the instant the next month is due; `rent_due_at`
  # is set when that debit could not be made because the balance was short,
  # and starts the seven-day grace before the contact is released. Additive:
  # nil on every existing row, and nothing reads either until the collector
  # runs.
  def change do
    alter table(:team_contacts) do
      add :rent_paid_through, :utc_datetime
      add :rent_due_at, :utc_datetime
    end

    create index(:team_contacts, [:rent_paid_through])
  end
end
