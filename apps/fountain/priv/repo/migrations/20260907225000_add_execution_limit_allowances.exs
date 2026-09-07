defmodule Fountain.Repo.Migrations.AddExecutionLimitAllowances do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :execution_limits, :map, null: false, default: %{}
    end

    alter table(:conversations) do
      add :execution_limits, :map, null: false, default: %{}
    end

    alter table(:turn_executions) do
      add :execution_limits, :map, null: false, default: %{}
    end
  end
end
