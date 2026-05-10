defmodule Fountain.Repo.Migrations.RenumberOnboardingStateForInferenceStep do
  @moduledoc """
  ADR 0008 inserts a new "Connect inference provider" step at the front of
  the onboarding wizard. The new step takes the slot `step_1`; existing
  step ids shift down (step_1 → step_2, step_2 → step_3, step_3 → step_4).

  Update existing user.onboarding_state values in reverse order so we don't
  re-rename a freshly bumped value.

  Users with state `"completed"` are unaffected.
  """

  use Ecto.Migration

  def up do
    execute("UPDATE users SET onboarding_state = 'step_4' WHERE onboarding_state = 'step_3'")
    execute("UPDATE users SET onboarding_state = 'step_3' WHERE onboarding_state = 'step_2'")
    execute("UPDATE users SET onboarding_state = 'step_2' WHERE onboarding_state = 'step_1'")
  end

  def down do
    execute("UPDATE users SET onboarding_state = 'step_1' WHERE onboarding_state = 'step_2'")
    execute("UPDATE users SET onboarding_state = 'step_2' WHERE onboarding_state = 'step_3'")
    execute("UPDATE users SET onboarding_state = 'step_3' WHERE onboarding_state = 'step_4'")
  end
end
