defmodule FountainWeb.BillingApiJSON do
  @moduledoc false

  def show(%{user: user, usage: usage, period_start: period_start, period_end: period_end}) do
    %{
      data: %{
        status: user.subscription_status,
        trial_ends_at: user.trial_ends_at,
        current_period_end: user.current_period_end,
        # Only an active subscription can be pending cancellation; once the
        # `.deleted` event lands the status is canceled and the flag clears.
        cancel_at_period_end:
          user.subscription_status == "active" and user.cancel_at_period_end == true,
        has_stripe_customer: user.stripe_customer_id not in [nil, ""],
        period: %{start: period_start, end: period_end},
        usage: %{
          conversations: usage.conversations,
          turns: usage.turns,
          sandbox_minutes: Float.round(usage.sandbox_minutes, 2)
        }
      }
    }
  end

  def url(%{url: url}), do: %{data: %{url: url}}
end
