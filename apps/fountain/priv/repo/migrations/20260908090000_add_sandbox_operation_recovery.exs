defmodule Fountain.Repo.Migrations.AddSandboxOperationRecovery do
  use Ecto.Migration

  def change do
    alter table(:sandbox_operations) do
      add :recovery_checked_at, :utc_datetime_usec
    end

    create index(:sandbox_operations, [:state, :submitted_at], where: "state = 'submitted'")

    create index(:sandbox_operations, [:action, :state, :recovery_checked_at],
             where: "holds_slot OR (action = 'destroy' AND state = 'uncertain')"
           )
  end
end
