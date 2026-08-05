defmodule FountainWeb.OnboardingJSON do
  @moduledoc false

  def show(%{user: user}) do
    %{
      data: %{
        state: user.onboarding_state,
        completed: not is_nil(user.onboarding_completed_at),
        completed_at: user.onboarding_completed_at
      }
    }
  end
end
