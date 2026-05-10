defmodule Fountain.Repo.Migrations.AddOnboardingStateToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :onboarding_state, :string, default: "step_1", null: false
    end
  end
end
