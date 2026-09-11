defmodule Fountain.Repo.Migrations.AddWaitingToTurns do
  use Ecto.Migration

  # A turn that ended with its permission request still open (#1635).
  #
  # `pending_permission` on its own cannot say whether a request is held
  # inside a running turn or has outlived one: the row looks the same either
  # way. `waiting` is that discriminator, and it is what every sweep reads —
  # a waiting turn is `completed`, so nothing that hunts for `running` rows
  # finds it.
  #
  # `permission_deadline` is the request's own expiry, on a column rather
  # than only inside the JSON, because the deadline has to survive the
  # sandbox suspending and the server restarting. A process timer cannot,
  # so `Fountain.Workers.DetachedRequestSweeper` reads this instead. The
  # partial index is the sweep's whole query.
  def change do
    alter table(:turns) do
      add :waiting, :boolean, null: false, default: false
      add :permission_deadline, :utc_datetime
    end

    create index(:turns, [:permission_deadline],
             where: "waiting",
             name: :turns_waiting_permission_deadline_index
           )
  end
end
