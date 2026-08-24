defmodule Fountain.Repo.Migrations.AddSandboxModeToBuzzIdentities do
  use Ecto.Migration

  # A hosted Buzz agent may name where its conversations run (ADR 0023 step
  # 8): `ephemeral`, `persistent`, or NULL for the agent's own default. The
  # harness passes it to `fountain acp --sandbox-mode`, so it is a launch
  # field — a change bounces the harness.
  def change do
    alter table(:buzz_identities) do
      add :sandbox_mode, :string, null: true
    end
  end
end
