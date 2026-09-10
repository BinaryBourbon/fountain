defmodule Fountain.Repo.Migrations.AddEnvironmentSetupTimeout do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :setup_timeout_seconds, :integer, null: false, default: 120
    end

    create constraint(:environments, :setup_timeout_seconds_range,
             check: "setup_timeout_seconds BETWEEN 1 AND 900"
           )
  end
end
