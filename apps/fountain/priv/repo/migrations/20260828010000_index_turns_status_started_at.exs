defmodule Fountain.Repo.Migrations.IndexTurnsStatusStartedAt do
  use Ecto.Migration

  # Supports AutonomousTurnReaper.sweep_stuck_turns/0 (#1197): `WHERE status
  # = 'running' AND started_at < cutoff`. `turns` carries no `updated_at`
  # (see the schema), so `started_at` is the only clock the sweep has, and
  # `running` is a small minority of all turns at any moment — the same
  # shape `sandboxes_status_index` and `sandboxes_inserted_at_index` exist
  # for on the sandbox side.
  def change do
    create index(:turns, [:status, :started_at])
  end
end
