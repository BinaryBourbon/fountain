defmodule Fountain.Repo.Migrations.NilifyUsageEventsUserOnDelete do
  use Ecto.Migration

  # NC-9 from the phase-3 validation report: `usage_events.user_id` was created
  # with no `on_delete`, which in Postgres means NO ACTION. Every other table
  # referencing `users` either cascades or nilifies, so this one column was
  # enough to make deleting a user fail at the database level — which is why
  # there has never been an account deletion path.
  #
  # Nilify rather than cascade. These rows are the input to usage and revenue
  # reporting, and once the user_id is gone they describe activity without
  # identifying anyone — the standard "anonymise rather than erase" position,
  # and it keeps historical totals from silently changing whenever an account
  # is closed.
  def up do
    alter table(:usage_events) do
      modify :user_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        from: references(:users, type: :binary_id),
        null: true
    end
  end

  def down do
    alter table(:usage_events) do
      modify :user_id, references(:users, type: :binary_id),
        from: references(:users, type: :binary_id, on_delete: :nilify_all),
        null: false
    end
  end
end
