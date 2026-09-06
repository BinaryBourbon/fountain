defmodule Fountain.Repo.Migrations.AddSandboxApiAccess do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :sandbox_api_access, :text, null: false, default: "owner"
    end

    create constraint(:conversations, :sandbox_api_access_valid,
             check: "sandbox_api_access IN ('owner', 'none')"
           )
  end
end
