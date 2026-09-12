defmodule Fountain.Repo.Migrations.TrackReappliedConfiguration do
  use Ecto.Migration

  # Three columns that let a conversation's selection be re-applied to the
  # machine it already runs on (#1565).
  #
  # `configuration_revision` counts committed selections. A turn is admitted
  # against the revision the server loaded, so a server that missed the
  # refresh notification cannot start a turn on settings it has not read.
  #
  # `build_fingerprint` records what the disk was actually built from: a
  # digest of the Environment fields provisioning turns into filesystem state
  # (packages, repositories, setup script, network policy). A reapply compares
  # it with the selection being asked for, so "your new environment installs
  # different packages" is answerable rather than assumed. Null on every row
  # that predates this, which reads as "unknown" and falls back to comparing
  # the environment the sandbox records.
  #
  # `applied_skills` is the skill selection the machine was last reconciled
  # to, so the next reconciliation knows what it owns.
  def change do
    alter table(:conversations) do
      add :configuration_revision, :bigint, null: false, default: 0
    end

    alter table(:sandboxes) do
      add :build_fingerprint, :string
      add :applied_skills, {:array, :map}
    end
  end
end
