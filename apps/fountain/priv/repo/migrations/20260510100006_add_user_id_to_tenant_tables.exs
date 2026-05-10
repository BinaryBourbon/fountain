defmodule Fountain.Repo.Migrations.AddUserIdToTenantTables do
  use Ecto.Migration

  def change do
    # environments — delete_all (user gone → environments gone)
    alter table(:environments) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    drop_if_exists unique_index(:environments, [:name])
    create unique_index(:environments, [:user_id, :name])
    create index(:environments, [:user_id])

    # agents — delete_all
    alter table(:agents) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    drop_if_exists unique_index(:agents, [:name])
    create unique_index(:agents, [:user_id, :name])
    create index(:agents, [:user_id])

    # vaults — delete_all
    alter table(:vaults) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    drop_if_exists unique_index(:vaults, [:name])
    create unique_index(:vaults, [:user_id, :name])
    create index(:vaults, [:user_id])

    # conversations — delete_all
    alter table(:conversations) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    create index(:conversations, [:user_id])

    # sandboxes — nilify_all (sandbox records kept for billing/audit after user deletion)
    alter table(:sandboxes) do
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sandboxes, [:user_id])
  end
end
