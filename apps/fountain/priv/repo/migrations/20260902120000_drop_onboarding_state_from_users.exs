defmodule Fountain.Repo.Migrations.DropOnboardingStateFromUsers do
  @moduledoc """
  Drop `users.onboarding_state` (#1393, NC-6 from ADR 0007).

  It was the wizard's position. The wizard went in #867, after which the
  column only ever held `step_1` or `completed` — which is exactly what
  `onboarding_completed_at` being null or set already says. ADR 0038 makes
  that stamp the one source of truth.

  `down/0` restores the column with its original default and NOT NULL, and
  backfills `completed` for the accounts whose stamp is set. It cannot restore
  which *step* an account had reached, because that information stopped being
  recorded when the wizard went; a rollback puts every unfinished account back
  at `step_1`, which is what the column would say about them today anyway.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      remove :onboarding_state
    end
  end

  def down do
    alter table(:users) do
      add :onboarding_state, :string, default: "step_1", null: false
    end

    execute(
      "UPDATE users SET onboarding_state = 'completed' WHERE onboarding_completed_at IS NOT NULL"
    )
  end
end
