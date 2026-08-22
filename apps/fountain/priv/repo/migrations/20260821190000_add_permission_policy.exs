defmodule Fountain.Repo.Migrations.AddPermissionPolicy do
  use Ecto.Migration

  # Per-tool permission policy (#939, ADR 0014 gate 3).
  #
  # `agents.permission_policy` is the agent's own map; `conversations` carries
  # a per-launch override that may only narrow it. Both default to an empty
  # map, which means "no opinion" and resolves to `auto_allow` — the behaviour
  # every conversation has today, so this migration changes nothing on its own.
  #
  # Nullable on conversations rather than defaulted: nil says "this launch had
  # no opinion", which is different from "this launch explicitly set nothing"
  # only in intent, but keeps the column honest about what the caller sent.
  def change do
    alter table(:agents) do
      add :permission_policy, :map, null: false, default: %{}
    end

    alter table(:conversations) do
      add :permission_policy, :map
    end
  end
end
