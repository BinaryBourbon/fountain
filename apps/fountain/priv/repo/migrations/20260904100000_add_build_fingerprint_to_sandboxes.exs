defmodule Fountain.Repo.Migrations.AddBuildFingerprintToSandboxes do
  use Ecto.Migration

  # What the machine's disk was actually built from: a digest of the
  # Environment fields that provisioning turns into filesystem state
  # (packages, repositories, setup script). Reapply compares it against the
  # selection being asked for, so "your new environment installs different
  # packages" is answerable rather than assumed. Null on every row that
  # predates this, which reads as "unknown" and falls back to comparing the
  # environment the sandbox records.
  def change do
    alter table(:sandboxes) do
      add :build_fingerprint, :string
    end
  end
end
