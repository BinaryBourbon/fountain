defmodule Fountain.Repo.Migrations.AddSandboxProviderToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      # Optional override of the instance-default sandbox backend. Null means
      # inherit SANDBOX_PROVIDER at conversation start.
      add :sandbox_provider, :string, null: true
    end
  end
end
