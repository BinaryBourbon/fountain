defmodule FountainWeb.OnboardingJSON do
  @moduledoc false

  # `completed` and `completed_at` both come from `onboarding_completed_at`,
  # which is the one source of truth since #1393. The `state` field went with
  # the column: it distinguished nothing that `completed` does not.
  def show(%{user: user}) do
    %{
      data: %{
        completed: not is_nil(user.onboarding_completed_at),
        completed_at: user.onboarding_completed_at
      }
    }
  end
end
