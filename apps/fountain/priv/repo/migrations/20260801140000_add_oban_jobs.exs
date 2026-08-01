defmodule Fountain.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # Background work previously ran as bare Task.start with no supervisor, no
  # retry and no durability: rehydration, sprite checkpointing, and Stripe
  # customer creation all vanished if the BEAM died mid-task. Oban gives those a
  # Postgres-backed queue, and its Cron plugin gives the scheduled pruning that
  # unbounded tables have needed since launch.
  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
